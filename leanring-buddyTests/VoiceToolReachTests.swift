//
//  VoiceToolReachTests.swift
//  leanring-buddyTests
//
//  Integration tests for the tools voice Dottie told users she didn't have:
//  typing and copying are declared up front (not hidden behind find_tool),
//  copy_to_clipboard is registered and declared with its schema, and
//  running it through the registry really puts the text on the clipboard.
//

import AppKit
import Foundation
import Testing
@testable import Dottie

@MainActor
struct VoiceToolReachTests {

    @Test func typingCopyingClickingAndOpeningPagesAreDeclaredUpFront() {
        for toolName in ["type_text", "copy_to_clipboard", "click_on_screen", "open_url", "do_task_on_screen", "write_notes", "explain_on_screen"] {
            #expect(DottieVoiceToolCatalog.directFunctionNames.contains(toolName), "\(toolName) should be a direct tool")
        }
    }

    @Test func theHiddenToolsLineNoLongerListsTyping() {
        #expect(DottieVoiceToolCatalog.hiddenToolAreasSummary.hasPrefix("scrolling"))
        #expect(DottieVoiceToolCatalog.hiddenToolAreasSummary.contains("typing") == false)
    }

    @Test func theClipboardModuleIsRegistered() {
        #expect(DottieToolModules.all.contains { ObjectIdentifier($0) == ObjectIdentifier(DottieClipboardTools.self) })
        #expect(DottieToolRegistry.handles("copy_to_clipboard", for: .voice))
    }

    @Test func theClipboardToolIsDeclaredWithARequiredText() {
        let declaration = DottieToolRegistry.functionDeclarations(for: .voice).first { ($0["name"] as? String) == "copy_to_clipboard" }
        #expect(declaration != nil)
        let parameters = declaration?["parameters"] as? [String: Any]
        let required = parameters?["required"] as? [String]
        #expect(required == ["text"])
    }

    @Test func copyingWithNoTextIsRefusedAndLeavesTheClipboardAlone() async {
        let clipboardBefore = NSPasteboard.general.string(forType: .string)
        let emptyResult = await DottieToolRegistry.run("copy_to_clipboard", arguments: ["text": ""], for: .voice)
        let missingResult = await DottieToolRegistry.run("copy_to_clipboard", arguments: [:], for: .voice)
        #expect(emptyResult?.hasPrefix("error") == true)
        #expect(missingResult?.hasPrefix("error") == true)
        #expect(NSPasteboard.general.string(forType: .string) == clipboardBefore)
    }

    @Test func copyingPutsTheExactTextOnTheClipboard() async {
        let clipboardBefore = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let clipboardBefore { NSPasteboard.general.setString(clipboardBefore, forType: .string) }
        }
        let command = "pip install transformers\nprint(model.generate(**inputs))"
        let result = await DottieToolRegistry.run("copy_to_clipboard", arguments: ["text": command], for: .voice)
        #expect(result?.contains("copied") == true)
        #expect(NSPasteboard.general.string(forType: .string) == command)
    }
}
