//
//  HomeCodeView.swift
//  leanring-buddy
//
//  Home → Code: a deliberately small code editor. A file tree on the left
//  (Projects, the Dots' folders, folders the user opened), the file on the
//  right in a plain NSTextView with light syntax colors, a Save button
//  (cmd+S), a command box that runs in the file's folder with its output
//  underneath, and an "Ask Coder" box that has a helper make the change.
//  No language servers, extensions or indexing: it opens instantly.
//

import AppKit
import SwiftUI

struct HomeCodeView: View {
    @ObservedObject private var workspace = DottieCodeWorkspace.shared
    @State private var commandText = ""
    @State private var helperRequestText = ""
    @State private var isShowingOutput = true

    var body: some View {
        HStack(spacing: 0) {
            fileTree
                .frame(width: 230)
            Divider()
            VStack(spacing: 0) {
                editorHeader
                Divider()
                if workspace.selectedFileURL != nil {
                    DottieCodeTextView(text: $workspace.editorText, fileExtension: workspace.selectedFileURL?.pathExtension ?? "")
                } else {
                    emptyEditor
                }
                Divider()
                bottomBar
                if isShowingOutput && !workspace.commandOutput.isEmpty {
                    outputConsole
                }
            }
        }
        .onAppear { workspace.startWatchingOpenFile() }
        .onDisappear { workspace.stopWatchingOpenFile() }
        .background(
            // cmd+S saves, as in any editor.
            Button("") { workspace.save() }
                .keyboardShortcut("s", modifiers: .command)
                .opacity(0)
        )
    }

    // MARK: Tree

    private var fileTree: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Code")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Button(action: { workspace.refreshTree() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Read the folders again")
                .pointerCursor()
                Button(action: { workspace.chooseFolderToOpen() }) {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                .help("Open a file or folder")
                .pointerCursor()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(workspace.roots) { root in
                        HomeCodeTreeRow(url: root.url, title: root.title, depth: 0, isRoot: true, workspace: workspace)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 10)
                .id(workspace.treeRevision)
            }
        }
        .background(DSVisualEffectBackground(material: .sidebar))
    }

    // MARK: Editor

    private var editorHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundColor(DS.Colors.textTertiary)
            Text(workspace.selectedFileURL?.lastPathComponent ?? "No file open")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            if workspace.hasUnsavedChanges {
                Circle().fill(DS.Colors.textTertiary).frame(width: 6, height: 6)
                    .help("Not saved yet")
            }
            if let folderPath = workspace.currentFolderURL?.path {
                Text(folderPath.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            if !workspace.statusLine.isEmpty {
                Text(workspace.statusLine)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            if let selectedFileURL = workspace.selectedFileURL {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([selectedFileURL]) }
                    .controlSize(.small)
                    .pointerCursor()
            }
            Button("Save") { workspace.save() }
                .controlSize(.small)
                .disabled(!workspace.hasUnsavedChanges)
                .pointerCursor()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyEditor: some View {
        VStack(spacing: 8) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 28))
                .foregroundColor(DS.Colors.textTertiary)
            Text("Pick a file on the left")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
            Text("Everything Dottie and the Dots build shows here. Or ask Dottie \u{201C}open the coffee store site in the code editor\u{201D}.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .foregroundColor(DS.Colors.textTertiary)
            TextField("Run in this folder, like npm start", text: $commandText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .onSubmit { runCommand() }
            Button(workspace.isRunningCommand ? "Running…" : "Run") { runCommand() }
                .controlSize(.small)
                .disabled(workspace.isRunningCommand || commandText.trimmingCharacters(in: .whitespaces).isEmpty)
                .pointerCursor()
            Divider().frame(height: 16)
            Image(systemName: "sparkles")
                .foregroundColor(DS.Colors.textTertiary)
            TextField("Ask Coder to change it", text: $helperRequestText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .onSubmit { askHelper() }
            Button("Ask") { askHelper() }
                .controlSize(.small)
                .disabled(helperRequestText.trimmingCharacters(in: .whitespaces).isEmpty)
                .pointerCursor()
            if !workspace.commandOutput.isEmpty {
                Button(action: { isShowingOutput.toggle() }) {
                    Image(systemName: isShowingOutput ? "chevron.down" : "chevron.up")
                }
                .buttonStyle(.borderless)
                .help(isShowingOutput ? "Hide the output" : "Show the output")
                .pointerCursor()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var outputConsole: some View {
        ScrollView {
            Text(workspace.commandOutput)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(DS.Colors.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(height: 140)
        .background(DS.Colors.surface2)
    }

    private func runCommand() {
        workspace.run(commandText)
    }

    private func askHelper() {
        _ = workspace.askHelper(helperRequestText)
        helperRequestText = ""
    }
}

/// One file or folder in the tree; folders open and close on click.
private struct HomeCodeTreeRow: View {
    let url: URL
    let title: String
    let depth: Int
    var isRoot = false
    @ObservedObject var workspace: DottieCodeWorkspace
    @State private var isExpanded = false
    @State private var isHovered = false

    private var isFolder: Bool { DottieCodeWorkspace.isFolder(url) }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button(action: {
                if isFolder {
                    isExpanded.toggle()
                } else {
                    workspace.open(url)
                }
            }) {
                HStack(spacing: 5) {
                    if isFolder {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(DS.Colors.textTertiary)
                            .frame(width: 10)
                    } else {
                        Spacer().frame(width: 10)
                    }
                    Image(systemName: isFolder ? "folder" : "doc.text")
                        .font(.system(size: 11))
                        .foregroundColor(isFolder ? DS.Colors.accentText : DS.Colors.textTertiary)
                    Text(title)
                        .font(.system(size: 12, weight: isRoot ? .semibold : .regular))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, CGFloat(depth) * 12 + 4)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(workspace.selectedFileURL == url ? DS.Colors.accent.opacity(0.18) : (isHovered ? DS.Colors.textPrimary.opacity(0.06) : Color.clear))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .onHover { isHovered = $0 }
            .contextMenu {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                if isRoot, workspace.openedFolderURLs.contains(url) {
                    Button("Remove from the list") { workspace.removeFolder(url) }
                }
            }

            if isFolder && isExpanded {
                ForEach(DottieCodeWorkspace.children(of: url), id: \.path) { childURL in
                    HomeCodeTreeRow(url: childURL, title: childURL.lastPathComponent, depth: depth + 1, workspace: workspace)
                }
            }
        }
    }
}

/// A plain-text code view: monospaced, no smart quotes or autocorrect,
/// and light syntax colors redrawn as the user types.
struct DottieCodeTextView: NSViewRepresentable {
    @Binding var text: String
    let fileExtension: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.font = Coordinator.codeFont
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.backgroundColor = .textBackgroundColor
        textView.string = text
        context.coordinator.highlight(textView, fileExtension: fileExtension)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.fileExtension = fileExtension
        // Only a change from outside (another file, a helper's edit)
        // replaces the text; typing already put it there.
        if textView.string != text {
            textView.string = text
            context.coordinator.highlight(textView, fileExtension: fileExtension)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        static let codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        private var text: Binding<String>
        var fileExtension = ""

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            highlight(textView, fileExtension: fileExtension)
        }

        private static let keywordPattern = "\\b(func|let|var|if|else|for|while|return|import|class|struct|enum|case|switch|default|guard|in|do|try|catch|throw|async|await|const|function|def|from|as|new|this|self|true|false|nil|null|None|True|False|public|private|static|extends|interface|type|export|break|continue|elif|lambda|with|yield|local|then|end|repeat|until|not|and|or)\\b"
        private static let stringPattern = "\"(\\\\.|[^\"\\\\])*\"|'(\\\\.|[^'\\\\])*'|`[^`]*`"
        private static let numberPattern = "\\b[0-9]+(\\.[0-9]+)?\\b"
        private static let lineCommentPattern = "(//|#|--)[^\\n]*"
        private static let blockCommentPattern = "/\\*[\\s\\S]*?\\*/"

        /// Keywords, strings, numbers and comments, in that order so a
        /// keyword inside a string or comment ends up colored as one.
        func highlight(_ textView: NSTextView, fileExtension: String) {
            guard let textStorage = textView.textStorage else { return }
            let fullRange = NSRange(location: 0, length: textStorage.length)
            // Very large files stay plain so typing stays quick.
            guard textStorage.length < 300_000 else { return }
            textStorage.beginEditing()
            textStorage.setAttributes([.font: Self.codeFont, .foregroundColor: NSColor.labelColor], range: fullRange)
            let isPlainText = ["txt", "md", "csv", "log", ""].contains(fileExtension.lowercased())
            if !isPlainText {
                color(Self.keywordPattern, NSColor.systemPink, in: textStorage)
                color(Self.numberPattern, NSColor.systemOrange, in: textStorage)
                color(Self.stringPattern, NSColor.systemGreen, in: textStorage)
                // "#" starts a comment in Python, shell and Ruby; "--" in Lua and SQL.
                let lineCommentPattern = ["swift", "js", "ts", "tsx", "jsx", "java", "c", "cpp", "h", "m", "go", "rs", "kt", "css", "scss"].contains(fileExtension.lowercased())
                    ? "//[^\\n]*"
                    : Self.lineCommentPattern
                color(lineCommentPattern, NSColor.secondaryLabelColor, in: textStorage)
                color(Self.blockCommentPattern, NSColor.secondaryLabelColor, in: textStorage)
            }
            textStorage.endEditing()
        }

        private func color(_ pattern: String, _ color: NSColor, in textStorage: NSTextStorage) {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
            let fullRange = NSRange(location: 0, length: textStorage.length)
            for match in expression.matches(in: textStorage.string, range: fullRange) {
                textStorage.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }
    }
}
