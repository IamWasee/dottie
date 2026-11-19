//
//  DottieClipboardTools.swift
//  leanring-buddy
//
//  copy_to_clipboard: voice Dottie puts text (a command, code, an address,
//  a draft) on the user's clipboard, so they can paste it anywhere. Before
//  this she had no way to and told the user she couldn't.
//

import AppKit
import Foundation

@MainActor
enum DottieClipboardTools: DottieToolModule {
    static let functionName = "copy_to_clipboard"

    static var tools: [DottieTool] {
        [
            DottieTool(
                name: functionName,
                description: "Put text on the user's clipboard so they can paste it with cmd+V: a command, code, an address, a draft message, an answer. Use it whenever the user says copy, or asks for commands or code to run (also write them on the notes board as a code block). Give the exact text, new lines included.",
                parameters: [
                    "type": "OBJECT",
                    "properties": [
                        "text": ["type": "STRING", "description": "Exactly the text to copy."]
                    ],
                    "required": ["text"]
                ],
                run: { arguments in
                    guard let text = arguments["text"] as? String, !text.isEmpty else {
                        return "error: give the text to copy."
                    }
                    copy(text)
                    return "copied to the clipboard. tell the user in a few words that it's ready to paste."
                }
            )
        ]
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
