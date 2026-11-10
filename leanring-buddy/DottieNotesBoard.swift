//
//  DottieNotesBoard.swift
//  leanring-buddy
//
//  Dottie's notes board (write_notes): a dark notebook window beside the
//  screen where she writes worked math and study notes as she explains:
//  headings, subheadings, paragraphs, bullet and numbered lists, equations
//  in real math symbols, parts of the text in other colors or highlighted,
//  and pictures (a screenshot of the screen, a part of it, or a picture
//  from the web).
//
//  It lays itself out like a person writing: the next step of the same
//  working goes to the right on the same line ("place": "right"), and a
//  new problem or section goes down. Equations never break onto a new
//  line; a line wider than the window scrolls sideways. The user can
//  scroll both ways, and every new block scrolls into view.
//
//  The notes are also saved as Markdown in Application Support/Dottie/Notes
//  so they can be read again later.
//

import AppKit
import Combine
import SwiftUI

struct DottieNoteBlock: Identifiable {
    enum Kind: String, CaseIterable {
        case heading, subheading, paragraph, bullet, numbered, equation, picture, divider
    }

    let id = UUID()
    let kind: Kind
    /// Pretty math with color markings (DottieInkText).
    let text: String
    let ink: DottieInk
    /// 0 for a top-level bullet, 1 or 2 for one under it.
    let indentLevel: Int
    /// For numbered blocks, worked out when added.
    var number: Int?
    let picture: NSImage?
}

struct DottieNoteRow: Identifiable {
    let id = UUID()
    var blocks: [DottieNoteBlock]
}

@MainActor
final class DottieNotesBoard: ObservableObject {
    static let shared = DottieNotesBoard()

    @Published private(set) var title = "Notes"
    @Published private(set) var rows: [DottieNoteRow] = []
    /// The block to scroll to once it's on the board.
    @Published private(set) var newestBlockID: UUID?

    private var notesPanel: NSPanel?
    private var notesFileURL: URL?
    private var writingTask: Task<Void, Never>?

    /// Seconds between blocks of one batch, so they appear the way a
    /// person writes them, one after another.
    private static let secondsBetweenBlocks: Double = 0.55

    var isShowing: Bool { notesPanel?.isVisible == true }

    // MARK: - Writing

    struct PlacedBlock {
        let block: DottieNoteBlock
        let goesRight: Bool
    }

    /// Writes the blocks one after another. Headings, subheadings and
    /// dividers always start a new line.
    func write(_ placedBlocks: [PlacedBlock]) {
        show()
        let earlierWritingTask = writingTask
        writingTask = Task { [weak self] in
            await earlierWritingTask?.value
            for placedBlock in placedBlocks {
                guard let self, !Task.isCancelled else { return }
                self.append(placedBlock)
                try? await Task.sleep(nanoseconds: UInt64(Self.secondsBetweenBlocks * 1_000_000_000))
            }
            self?.saveMarkdown()
        }
    }

    private func append(_ placedBlock: PlacedBlock) {
        var block = placedBlock.block
        if block.kind == .numbered {
            let previousBlock = rows.last?.blocks.last
            if let previousBlock, previousBlock.kind == .numbered, previousBlock.indentLevel == block.indentLevel {
                block.number = (previousBlock.number ?? 0) + 1
            } else {
                block.number = 1
            }
        }
        let alwaysStartsNewLine = [.heading, .subheading, .divider].contains(block.kind)
        if placedBlock.goesRight, !alwaysStartsNewLine, !rows.isEmpty {
            rows[rows.count - 1].blocks.append(block)
        } else {
            rows.append(DottieNoteRow(blocks: [block]))
        }
        newestBlockID = block.id
    }

    /// A fresh page. Its title names the saved file.
    func startNewPage(title newTitle: String?) {
        writingTask?.cancel()
        writingTask = nil
        rows.removeAll()
        newestBlockID = nil
        title = newTitle?.isEmpty == false ? newTitle! : "Notes"
        notesFileURL = nil
    }

    // MARK: - The window

    func show() {
        if let notesPanel {
            notesPanel.orderFrontRegardless()
            return
        }
        let screenFrame = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let panelWidth = min(640, screenFrame.width * 0.45)
        let panelHeight = screenFrame.height * 0.86
        let panelFrame = CGRect(
            x: screenFrame.maxX - panelWidth - 20,
            y: screenFrame.midY - panelHeight / 2,
            width: panelWidth,
            height: panelHeight
        )
        // Non-activating, so opening it never takes the keyboard away from
        // the app the user is in; it still scrolls and takes clicks.
        let panel = NSPanel(
            contentRect: panelFrame,
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = NSColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 0.97)
        panel.contentView = NSHostingView(rootView: DottieNotesBoardView(notesBoard: self))
        panel.orderFrontRegardless()
        notesPanel = panel
    }

    func close() {
        notesPanel?.orderOut(nil)
    }

    // MARK: - Saving

    private static var notesFolderURL: URL {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupportURL.appendingPathComponent("Dottie/Notes", isDirectory: true)
    }

    /// The page as Markdown, colors and highlights left out.
    var markdown: String {
        var lines = ["# \(title)", ""]
        for row in rows {
            let rowTexts = row.blocks.map { block -> String in
                let plainText = DottieInkText.plainText(block.text)
                let indent = String(repeating: "  ", count: block.indentLevel)
                switch block.kind {
                case .heading: return "## \(plainText)"
                case .subheading: return "### \(plainText)"
                case .paragraph: return plainText
                case .bullet: return "\(indent)- \(plainText)"
                case .numbered: return "\(indent)\(block.number ?? 1). \(plainText)"
                case .equation: return "    \(plainText)"
                case .picture: return "[picture\(plainText.isEmpty ? "" : ": \(plainText)")]"
                case .divider: return "---"
                }
            }
            // Blocks written side by side stay on one line.
            lines.append(rowTexts.joined(separator: "    "))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func saveMarkdown() {
        guard !rows.isEmpty else { return }
        if notesFileURL == nil {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd HH.mm"
            let safeTitle = title.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
            notesFileURL = Self.notesFolderURL.appendingPathComponent("\(dateFormatter.string(from: Date())) \(safeTitle).md")
        }
        guard let notesFileURL else { return }
        try? FileManager.default.createDirectory(at: Self.notesFolderURL, withIntermediateDirectories: true)
        DottieFileSaver.save(text: markdown, to: notesFileURL)
    }

    func revealSavedNotes() {
        if let notesFileURL, FileManager.default.fileExists(atPath: notesFileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([notesFileURL])
        } else {
            try? FileManager.default.createDirectory(at: Self.notesFolderURL, withIntermediateDirectories: true)
            NSWorkspace.shared.open(Self.notesFolderURL)
        }
    }
}

// MARK: - Views

private struct DottieNotesBoardView: View {
    @ObservedObject var notesBoard: DottieNotesBoard

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollViewReader { scrollProxy in
                // Both ways: equations never wrap, so a long line of
                // working scrolls sideways instead of running off the edge.
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(notesBoard.rows) { row in
                            HStack(alignment: .firstTextBaseline, spacing: 36) {
                                ForEach(row.blocks) { block in
                                    DottieNoteBlockView(block: block)
                                        .id(block.id)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                    .frame(minWidth: 0, alignment: .topLeading)
                }
                .onChange(of: notesBoard.newestBlockID) { _, newestBlockID in
                    guard let newestBlockID else { return }
                    withAnimation(.easeOut(duration: 0.35)) {
                        scrollProxy.scrollTo(newestBlockID, anchor: .bottomTrailing)
                    }
                }
            }
        }
        .frame(minWidth: 360, minHeight: 300, alignment: .topLeading)
        .background(Color(red: 0.08, green: 0.09, blue: 0.12))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(notesBoard.title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.75))
                .lineLimit(1)
            Spacer()
            headerButton(systemImageName: "folder", helpText: "Show saved notes") {
                notesBoard.revealSavedNotes()
            }
            headerButton(systemImageName: "doc.on.doc", helpText: "Copy the notes") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(notesBoard.markdown, forType: .string)
            }
            headerButton(systemImageName: "trash", helpText: "Clear the page") {
                notesBoard.startNewPage(title: nil)
            }
        }
        // Room for the window's close button on the left.
        .padding(.leading, 78)
        .padding(.trailing, 14)
        .frame(height: 30)
    }

    private func headerButton(systemImageName: String, helpText: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImageName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .pointerCursor()
    }
}

/// One block, written in left to right like a pen.
private struct DottieNoteBlockView: View {
    let block: DottieNoteBlock
    @State private var writingProgress: CGFloat = 0

    /// Paragraphs and list items wrap at this width; equations never do.
    private static let wrappingWidth: CGFloat = 520

    private static func handwriting(size: CGFloat) -> Font {
        NSFont(name: "Noteworthy-Bold", size: size) != nil
            ? .custom("Noteworthy-Bold", size: size)
            : .system(size: size, weight: .semibold, design: .rounded)
    }

    var body: some View {
        content
            .mask(
                GeometryReader { proxy in
                    Rectangle().frame(width: proxy.size.width * writingProgress, height: proxy.size.height)
                }
            )
            .onAppear {
                let plainLength = DottieInkText.plainText(block.text).count
                let writingSeconds = block.kind == .picture ? 0.5 : min(max(Double(plainLength) * 0.035, 0.3), 1.8)
                withAnimation(.linear(duration: writingSeconds)) {
                    writingProgress = 1
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        let indent = CGFloat(block.indentLevel) * 24
        switch block.kind {
        case .heading:
            writtenText(size: 30)
                .padding(.top, 10)
                .frame(maxWidth: Self.wrappingWidth + 160, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        case .subheading:
            writtenText(size: 23)
                .opacity(0.95)
                .padding(.top, 4)
                .frame(maxWidth: Self.wrappingWidth + 80, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph:
            writtenText(size: 19)
                .frame(maxWidth: Self.wrappingWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet, .numbered:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(block.kind == .numbered ? "\(block.number ?? 1)." : (block.indentLevel == 0 ? "•" : "◦"))
                    .font(Self.handwriting(size: 19))
                    .foregroundColor(block.ink.color.opacity(0.8))
                writtenText(size: 19)
                    .frame(maxWidth: Self.wrappingWidth - indent, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, indent)
        case .equation:
            // One line, never broken: a long one scrolls sideways.
            writtenText(size: 25)
                .fixedSize()
                .padding(.leading, indent)
        case .picture:
            VStack(alignment: .leading, spacing: 6) {
                if let picture = block.picture {
                    Image(nsImage: picture)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 460, maxHeight: 300, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.15), lineWidth: 1))
                }
                if !block.text.isEmpty {
                    writtenText(size: 15)
                        .opacity(0.8)
                        .frame(maxWidth: 460, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .divider:
            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: Self.wrappingWidth, height: 1)
                .padding(.vertical, 6)
        }
    }

    private func writtenText(size: CGFloat) -> some View {
        Text(DottieInkText.attributedString(block.text))
            .font(Self.handwriting(size: size))
            .foregroundColor(block.ink.color)
            .textSelection(.enabled)
    }
}

// MARK: - Voice tool

@MainActor
enum DottieNotesTools: DottieToolModule {
    static let functionName = "write_notes"

    static var tools: [DottieTool] {
        [
            DottieTool(
                name: functionName,
                description: "Write notes on Dottie's notes board, a dark notebook window beside the screen, while you explain: worked math and science, study notes, summaries, step-by-step solutions. Use it on your own whenever an explanation has working, formulas or several points worth keeping, and for any ask to take or write notes. blocks are written in order, like a person writing: heading for a topic, subheading for a part, paragraph for a sentence or two, bullet and numbered for lists (indent 1 or 2 for points under a point), equation for one line of math, picture for a screenshot or a picture from the web, divider between sections. Write math and science in real symbols, never in words: \"p = ¹⁄₁₆x⁴\", \"(¹⁄₁₆x⁴)^½ = ¼x²\", \"3 × 4 ÷ 2\", \"a² + b² = c²\", \"√x\", \"∫ x² dx\", \"Δv/Δt\", \"x ≤ 3\", \"π r²\", \"θ = 30°\", \"H₂O\", \"CO₂ + H₂O ⇌ H₂CO₃\", \"SO₄²⁻\", \"F = ma\", \"9.8 m/s²\"; x^2, *, sqrt, ->, <=>, H2O typed plainly are turned into symbols too. Color part of a line to highlight it: {red:key term}, {blue:…}, {green:…}, {yellow:…}, {highlight:…} for a marker wash, **bold**. Write for someone who doesn't think in symbols: state the rule first as a short line with {highlight:…} (\"Dividing powers: subtract the powers\"); then one small change per equation, each followed with place right by a short plain-words reason in a color (\"{blue:minus a minus is a plus}\"); give the parts that belong together the same color (the 3 and the −3 both {red:…}); when a shortcut way of seeing it helps, add it as a paragraph (\"x⁻³ on the bottom is the same as x³ on top\"); end with the answer alone as {highlight:…}. Never * or ^ in what you write. Numbers: digits in math, measurements, money, times, dates, scores and anything 10 or more (3x⁶, 5 cm, $12, 9:30, 42); words for small everyday counts in a sentence (\"two ways to do this\", \"the first step\"); if the user asks for one style, use that from then on. place right keeps going on the same line: the next step of the same working, its reason, or a second equation beside it; down (the default) starts a new line, for a new problem, point or section. Equations never wrap; the board scrolls both ways. Each call adds to the page; new_page true starts a clean page with that title. After calling, say only a few words; say the explanation itself, don't read the notes out word for word.",
                parameters: [
                    "type": "OBJECT",
                    "properties": [
                        "blocks": [
                            "type": "ARRAY",
                            "items": [
                                "type": "OBJECT",
                                "properties": [
                                    "kind": ["type": "STRING", "enum": DottieNoteBlock.Kind.allCases.map(\.rawValue)],
                                    "text": ["type": "STRING", "description": "The words or math, with {color:…} or **bold** where something should stand out. For a picture, its caption."],
                                    "place": ["type": "STRING", "enum": ["right", "down"], "description": "right: same line, after the last block (the next step of the same working). down: a new line. Default down."],
                                    "indent": ["type": "INTEGER", "description": "bullet or numbered under another point: 1 or 2. Default 0."],
                                    "color": ["type": "STRING", "enum": DottieInk.allCases.map(\.rawValue), "description": "The whole block's pen color. Default white, gold for headings."],
                                    "picture": ["type": "STRING", "description": "picture only: \"screen\" for a screenshot of the screen, \"screen: <what to cut out, described>\" for just one part of it (like \"screen: the graph in the middle of the video\"), or a web address of a picture or of a page with a picture."]
                                ],
                                "required": ["kind"]
                            ]
                        ],
                        "new_page": ["type": "BOOLEAN", "description": "Start a clean page first. Use for a new topic; leave it out to keep adding."],
                        "title": ["type": "STRING", "description": "With new_page: the page's title, like \"Indices: fractional powers\"."],
                        "action": ["type": "STRING", "enum": ["write", "show", "close", "clear"], "description": "write (default) adds the blocks; show brings the board back; close hides it; clear empties the page."]
                    ]
                ],
                audiences: [.voice]
            ) { arguments in
                await perform(arguments)
            }
        ]
    }

    private static func perform(_ arguments: [String: Any]) async -> String {
        let notesBoard = DottieNotesBoard.shared
        switch (arguments["action"] as? String)?.lowercased() ?? "write" {
        case "show":
            notesBoard.show()
            return "the notes board is open."
        case "close":
            notesBoard.close()
            return "closed the notes board."
        case "clear":
            notesBoard.startNewPage(title: arguments["title"] as? String)
            return "cleared the notes board."
        default:
            break
        }

        let startsNewPage = (arguments["new_page"] as? Bool) ?? ((arguments["new_page"] as? NSNumber)?.boolValue ?? false)
        if startsNewPage {
            notesBoard.startNewPage(title: (arguments["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let rawBlocks = ((arguments["blocks"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }.prefix(60)
        guard !rawBlocks.isEmpty else { return "error: give blocks, each with a kind and text." }

        var placedBlocks: [DottieNotesBoard.PlacedBlock] = []
        var pictureProblems: [String] = []
        for rawBlock in rawBlocks {
            guard let kind = (rawBlock["kind"] as? String).flatMap({ DottieNoteBlock.Kind(rawValue: $0.lowercased()) }) else { continue }
            let text = DottieMathText.pretty((rawBlock["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            if kind != .picture && kind != .divider && text.isEmpty { continue }
            let defaultInk: DottieInk = (kind == .heading || kind == .subheading) ? .gold : .white
            let ink = (rawBlock["color"] as? String).flatMap { DottieInk(rawValue: $0.lowercased()) } ?? defaultInk
            let indentLevel = min(max((rawBlock["indent"] as? NSNumber)?.intValue ?? 0, 0), 2)

            var picture: NSImage?
            if kind == .picture {
                let pictureSource = (rawBlock["picture"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "screen"
                picture = await DottieNotesPictures.picture(from: pictureSource)
                if picture == nil {
                    pictureProblems.append(pictureSource)
                    continue
                }
            }
            let goesRight = (rawBlock["place"] as? String)?.lowercased() == "right"
            placedBlocks.append(DottieNotesBoard.PlacedBlock(
                block: DottieNoteBlock(kind: kind, text: text, ink: ink, indentLevel: indentLevel, number: nil, picture: picture),
                goesRight: goesRight
            ))
        }
        guard !placedBlocks.isEmpty else {
            return pictureProblems.isEmpty ? "error: nothing to write." : "couldn't get the picture (\(pictureProblems.joined(separator: ", "))). say so in a few words."
        }
        notesBoard.write(placedBlocks)
        var result = "writing \(placedBlocks.count) block\(placedBlocks.count == 1 ? "" : "s") on the notes board. say a few words, not the notes themselves."
        if !pictureProblems.isEmpty {
            result += " couldn't get the picture from \(pictureProblems.joined(separator: ", "))."
        }
        return result
    }
}

// MARK: - Pictures

@MainActor
enum DottieNotesPictures {
    /// "screen", "screen: <part described>" or a web address.
    static func picture(from source: String) async -> NSImage? {
        let loweredSource = source.lowercased()
        if loweredSource == "screen" || loweredSource.hasPrefix("screen:") {
            let partDescription = loweredSource.hasPrefix("screen:")
                ? String(source.dropFirst("screen:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            return await screenPicture(partDescription: partDescription)
        }
        var address = source
        if !address.contains("://") { address = "https://" + address }
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return await webPicture(from: url)
    }

    /// The screen, or one part of it found the way drawings find things
    /// (one sharp screenshot, every anchor at once).
    private static func screenPicture(partDescription: String) async -> NSImage? {
        // The notes board itself shouldn't be in its own picture.
        let notesBoardWasShowing = DottieNotesBoard.shared.isShowing
        if notesBoardWasShowing { DottieNotesBoard.shared.close() }
        defer { if notesBoardWasShowing { DottieNotesBoard.shared.show() } }
        try? await Task.sleep(nanoseconds: 150_000_000)

        guard let screenshot = await DottieDisplayCapture.captureActiveDisplay(maximumDimension: 2000) else { return nil }
        let wholeScreenPicture = NSImage(cgImage: screenshot.image, size: NSSize(width: screenshot.image.width, height: screenshot.image.height))
        guard !partDescription.isEmpty else { return wholeScreenPicture }

        let foundFrames = await DottieTeaching.locateAnchors(
            [DottieTeaching.Anchor(name: "part", description: partDescription)],
            displayFrame: screenshot.displayFrame,
            userQuestion: partDescription
        )
        guard let partFrame = foundFrames["part"] else { return wholeScreenPicture }
        // Global AppKit points (bottom-left origin) → screenshot pixels
        // (top-left origin), with a little room around the part.
        let paddedFrame = partFrame.insetBy(dx: -12, dy: -12).intersection(screenshot.displayFrame)
        let pixelsPerPoint = CGFloat(screenshot.image.width) / screenshot.displayFrame.width
        let pixelRect = CGRect(
            x: (paddedFrame.minX - screenshot.displayFrame.minX) * pixelsPerPoint,
            y: (screenshot.displayFrame.maxY - paddedFrame.maxY) * pixelsPerPoint,
            width: paddedFrame.width * pixelsPerPoint,
            height: paddedFrame.height * pixelsPerPoint
        ).integral
        guard let croppedImage = screenshot.image.cropping(to: pixelRect) else { return wholeScreenPicture }
        return NSImage(cgImage: croppedImage, size: NSSize(width: croppedImage.width, height: croppedImage.height))
    }

    /// A picture's address, or a page's: then the page's own preview
    /// picture (og:image), the one sites show when they're shared.
    private static func webPicture(from url: URL) async -> NSImage? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (responseData, response) = try? await URLSession.shared.data(for: request) else { return nil }
        let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if contentType.hasPrefix("image/") || !contentType.contains("html"), let image = NSImage(data: responseData) {
            return image
        }
        guard contentType.contains("html"),
              let pageText = String(data: responseData.prefix(400_000), encoding: .utf8) ?? String(data: responseData.prefix(400_000), encoding: .isoLatin1),
              let previewAddress = previewPictureAddress(in: pageText),
              let previewURL = URL(string: previewAddress, relativeTo: url)?.absoluteURL,
              previewURL != url else { return nil }
        guard let (pictureData, _) = try? await URLSession.shared.data(from: previewURL) else { return nil }
        return NSImage(data: pictureData)
    }

    private static func previewPictureAddress(in pageText: String) -> String? {
        let patterns = [
            #"<meta[^>]+property=["']og:image(?::url)?["'][^>]+content=["']([^"']+)["']"#,
            #"<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:image(?::url)?["']"#,
            #"<meta[^>]+name=["']twitter:image["'][^>]+content=["']([^"']+)["']"#
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = expression.firstMatch(in: pageText, range: NSRange(pageText.startIndex..., in: pageText)),
                  let addressRange = Range(match.range(at: 1), in: pageText) else { continue }
            return String(pageText[addressRange]).replacingOccurrences(of: "&amp;", with: "&")
        }
        return nil
    }
}
