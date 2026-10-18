//
//  DottieFixText.swift
//  leanring-buddy
//
//  "Fix this" on any selected text, in any app: shorter, longer, fix
//  spelling and grammar, more formal, more casual, translate, or a custom
//  instruction. The selection is read through Accessibility (or copied
//  with Cmd+C, putting the user's clipboard back after), rewritten with
//  one quick Gemini call, and put back in place: set through
//  Accessibility where the app supports it, otherwise pasted. Password
//  fields are never read or touched.
//

import AppKit
import ApplicationServices
import Carbon
import Foundation

@MainActor
enum DottieFixText {
    enum Style: String, CaseIterable {
        case shorter
        case longer
        case fixGrammar = "fix_grammar"
        case formal
        case casual
        case translate
        case custom

        var doneWord: String {
            switch self {
            case .shorter: return "shortened"
            case .longer: return "expanded"
            case .fixGrammar: return "fixed"
            case .formal: return "made more formal"
            case .casual: return "made more casual"
            case .translate: return "translated"
            case .custom: return "rewritten"
            }
        }
    }

    private static let model = "gemini-3.5-flash-lite"
    private static let maximumTextLength = 12_000
    private static var isRunning = false

    /// The selection in the app in front, as Accessibility sees it.
    private struct Selection {
        let element: AXUIElement?
        let processIdentifier: pid_t
        let appName: String
        let isEditable: Bool
        let isSecure: Bool
        let selectedText: String
    }

    /// Rewrites the selection and puts it back. Returns what happened, for
    /// Dottie to relay (the shortcut shows it in the notch instead).
    static func run(style: Style, language: String? = nil, instruction: String? = nil, fromShortcut: Bool) async -> String {
        guard !isRunning else { return "still working on the last one." }
        guard AXIsProcessTrusted() else {
            return finish("Dottie needs Accessibility permission to fix text. Turn it on in System Settings → Privacy & Security → Accessibility.", fromShortcut: fromShortcut)
        }
        guard style != .custom || !(instruction ?? "").isEmpty else {
            return "say how to rewrite it (custom needs an instruction)."
        }
        isRunning = true
        defer { isRunning = false }

        guard let selection = captureSelection() else {
            return finish("Couldn't tell which app you're in.", fromShortcut: fromShortcut)
        }
        guard !selection.isSecure else {
            return finish("That's a password field, so I'm not touching it.", fromShortcut: fromShortcut)
        }

        var originalText = selection.selectedText
        var didCopyToRead = false
        if originalText.isEmpty {
            originalText = await copySelectionKeepingClipboard() ?? ""
            didCopyToRead = true
        }
        guard !originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return finish("Nothing is selected. Select some text first, then try again.", fromShortcut: fromShortcut)
        }
        guard originalText.count <= maximumTextLength else {
            return finish("That's a lot of text. Select a shorter part (up to about 2,000 words).", fromShortcut: fromShortcut)
        }

        let notchPresenter = DottieEveryday.shared.notchPresenter
        let showsProgress = fromShortcut && notchPresenter?.surface == .compact
        if showsProgress {
            notchPresenter?.showThinking(label: "fixing")
        }
        let rewrittenText = await rewrite(originalText, style: style, language: language, instruction: instruction)
        if showsProgress, notchPresenter?.surface == .thinking {
            notchPresenter?.collapse()
        }
        guard let rewrittenText, !rewrittenText.isEmpty else {
            return finish("Couldn't reach Gemini just now. Try again in a moment.", fromShortcut: fromShortcut)
        }
        if rewrittenText == originalText {
            DottieEveryday.shared.tell(title: "Already good", text: "Nothing to change in that text.")
            return "the text was already fine; nothing changed. tell them in a few words."
        }

        let isSameAppInFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == selection.processIdentifier
        guard selection.isEditable, isSameAppInFront, !IsSecureEventInputEnabled() else {
            copyToClipboard(rewrittenText)
            DottieEveryday.shared.tell(
                title: "Copied the new text",
                text: "\(preview(rewrittenText))\n\nThat text can't be edited here, so it's on your clipboard. Paste it where you want it."
            )
            return "couldn't edit that text in place, so the \(style.doneWord) version is on their clipboard. tell them to paste it."
        }

        let didSetInPlace = !didCopyToRead && replaceThroughAccessibility(selection, with: rewrittenText)
        if !didSetInPlace {
            pasteKeepingClipboard(rewrittenText)
        }

        let processIdentifier = selection.processIdentifier
        DottieEveryday.shared.tell(
            title: "Fixed ✓",
            text: "\(preview(rewrittenText))\n\nChanged your mind? Undo, or press Cmd+Z.",
            actionLabel: "Undo",
            action: { undo(inProcess: processIdentifier) }
        )
        let languageNote = style == .translate ? " into \(language ?? "English")" : ""
        return "\(style.doneWord) the selected text\(languageNote) in \(selection.appName) and put it in place. just say a quick done; don't read it out."
    }

    /// Shortcut errors show in the notch; voice errors go back to Dottie.
    private static func finish(_ message: String, fromShortcut: Bool) -> String {
        if fromShortcut {
            DottieEveryday.shared.tell(title: "Fix text", text: message)
        }
        return message
    }

    private static func preview(_ text: String) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return oneLine.count > 160 ? String(oneLine.prefix(159)) + "…" : oneLine
    }

    // MARK: - Rewriting

    private static func rewrite(_ text: String, style: Style, language: String?, instruction: String?) async -> String? {
        let task: String
        switch style {
        case .shorter:
            task = "Make this shorter and tighter. Keep the meaning, the tone and the language."
        case .longer:
            task = "Make this a bit longer and fuller, without inventing facts. Keep the tone and the language."
        case .fixGrammar:
            task = "Fix spelling, grammar and punctuation only. Change as little as possible. Keep the tone and the language."
        case .formal:
            task = "Rewrite this to sound more formal and professional. Keep the language."
        case .casual:
            task = "Rewrite this to sound more casual and friendly. Keep the language."
        case .translate:
            task = "Translate this into \(language ?? "English"). Keep the tone and the formatting."
        case .custom:
            task = instruction ?? "Improve this."
        }
        let system = """
        You edit text for the user. Reply with only the edited text: no quotes around it, no preface, no explanation, no code fences. \
        Keep line breaks, lists and formatting unless the instruction says otherwise. If nothing needs changing, return the text exactly as it is.
        """
        let requestBody: [String: Any] = [
            "model": model,
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": "Instruction: \(task)\n\nText:\n\(text)"]]]],
            "generationConfig": ["maxOutputTokens": min(8192, max(512, text.count))]
        ]
        guard let answer = await DottieChat.send(requestBody, timeout: 30) else { return nil }
        return keepingOuterWhitespace(of: text, around: cleaned(answer))
    }

    /// Drops code fences or quotes a model sometimes wraps the text in.
    private static func cleaned(_ answer: String) -> String {
        var text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            var lines = text.components(separatedBy: "\n")
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true { lines.removeLast() }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// A selection that ended with a line break keeps it.
    private static func keepingOuterWhitespace(of original: String, around rewritten: String) -> String {
        let leading = String(original.prefix { $0.isWhitespace })
        let trailing = String(original.reversed().prefix { $0.isWhitespace }.reversed())
        return leading + rewritten + trailing
    }

    // MARK: - Reading the selection

    private static func captureSelection() -> Selection? {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else { return nil }
        let appName = frontmostApplication.localizedName ?? "the app"
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            // Nothing focused that Accessibility can see: Cmd+C may still
            // find a selection, and pasting is the way back.
            return Selection(
                element: nil,
                processIdentifier: frontmostApplication.processIdentifier,
                appName: appName,
                isEditable: true,
                isSecure: IsSecureEventInputEnabled(),
                selectedText: ""
            )
        }
        let element = focusedValue as! AXUIElement
        var processIdentifier = frontmostApplication.processIdentifier
        AXUIElementGetPid(element, &processIdentifier)

        let role = stringAttribute(kAXRoleAttribute, of: element)
        let subrole = stringAttribute(kAXSubroleAttribute, of: element)
        let isSecure = role == "AXSecureTextField" || subrole == "AXSecureTextField" || IsSecureEventInputEnabled()
        guard !isSecure else {
            return Selection(element: element, processIdentifier: processIdentifier, appName: appName, isEditable: false, isSecure: true, selectedText: "")
        }

        let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
        var isValueSettable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &isValueSettable)
        var isSelectionSettable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &isSelectionSettable)
        // Web pages and Electron apps often report a plain group; editing
        // still works there by pasting, so only a clearly read-only element
        // (static text, a web page's body) counts as not editable.
        let readOnlyRoles: Set<String> = ["AXStaticText", "AXWebArea", "AXImage", "AXButton", "AXLink"]
        let isEditable = editableRoles.contains(role ?? "") || isValueSettable.boolValue || isSelectionSettable.boolValue
            || !readOnlyRoles.contains(role ?? "")

        return Selection(
            element: element,
            processIdentifier: processIdentifier,
            appName: NSRunningApplication(processIdentifier: processIdentifier)?.localizedName ?? appName,
            isEditable: isEditable,
            isSecure: false,
            selectedText: stringAttribute(kAXSelectedTextAttribute, of: element) ?? ""
        )
    }

    private static func stringAttribute(_ attributeName: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attributeName as CFString, &value) == .success else { return nil }
        return value as? String
    }

    // MARK: - Putting it back

    /// Sets the selected text through Accessibility, then checks the field
    /// really changed (some apps say yes and do nothing). False means paste.
    private static func replaceThroughAccessibility(_ selection: Selection, with newText: String) -> Bool {
        guard let element = selection.element else { return false }
        var isSettable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &isSettable) == .success,
              isSettable.boolValue,
              let valueBefore = stringAttribute(kAXValueAttribute, of: element),
              valueBefore.count < 200_000,
              valueBefore.contains(selection.selectedText) else { return false }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, newText as CFTypeRef) == .success else {
            return false
        }
        guard let valueAfter = stringAttribute(kAXValueAttribute, of: element) else { return false }
        return valueAfter != valueBefore && valueAfter.contains(newText)
    }

    private static func undo(inProcess processIdentifier: pid_t) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier else {
            NSRunningApplication(processIdentifier: processIdentifier)?.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { postKey(keyCode: CGKeyCode(kVK_ANSI_Z)) }
            return
        }
        postKey(keyCode: CGKeyCode(kVK_ANSI_Z))
    }

    // MARK: - Clipboard

    private typealias SavedClipboard = [[(NSPasteboard.PasteboardType, Data)]]

    private static func saveClipboard() -> SavedClipboard {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    private static func restoreClipboard(_ savedItems: SavedClipboard) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let restoredItems = savedItems.map { savedTypes -> NSPasteboardItem in
            let restoredItem = NSPasteboardItem()
            for (type, data) in savedTypes {
                restoredItem.setData(data, forType: type)
            }
            return restoredItem
        }
        if !restoredItems.isEmpty {
            pasteboard.writeObjects(restoredItems)
        }
    }

    /// Cmd+C, read what it copied, and put the user's clipboard back.
    private static func copySelectionKeepingClipboard() async -> String? {
        let pasteboard = NSPasteboard.general
        let savedItems = saveClipboard()
        let changeCountBefore = pasteboard.changeCount
        postKey(keyCode: CGKeyCode(kVK_ANSI_C))
        for _ in 0..<25 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if pasteboard.changeCount != changeCountBefore { break }
        }
        guard pasteboard.changeCount != changeCountBefore else { return nil }
        let copiedText = pasteboard.string(forType: .string)
        restoreClipboard(savedItems)
        return copiedText
    }

    private static func pasteKeepingClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let savedItems = saveClipboard()
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let changeCountAfterOurWrite = pasteboard.changeCount
        postKey(keyCode: CGKeyCode(kVK_ANSI_V))
        // Give the app time to read it, then put the user's clipboard back
        // unless something else has replaced ours.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard pasteboard.changeCount == changeCountAfterOurWrite else { return }
            restoreClipboard(savedItems)
        }
    }

    private static func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Cmd + the key, posted to the app in front.
    private static func postKey(keyCode: CGKeyCode) {
        let eventSource = CGEventSource(stateID: .combinedSessionState)
        let keyDownEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: true)
        let keyUpEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: false)
        keyDownEvent?.flags = .maskCommand
        keyUpEvent?.flags = .maskCommand
        keyDownEvent?.post(tap: .cghidEventTap)
        keyUpEvent?.post(tap: .cghidEventTap)
    }
}
