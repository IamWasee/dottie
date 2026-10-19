//
//  DottieEpisodicMemoryTools.swift
//  leanring-buddy
//
//  The memories tool, for voice Dottie and her helpers: look things up in
//  the episodic memory ("that site I was on", "what did we talk about
//  yesterday"), list what happened lately, or forget something.
//

import Foundation

@MainActor
enum DottieEpisodicMemoryTools: DottieToolModule {
    static var tools: [DottieTool] {
        [
            DottieTool(
                name: "memories",
                description: "Dottie's memory of what happened: conversations with the user, what helpers and screen jobs did, and (if the user turned it on) what was on their screen. Each episode has when, where (app, window, web page), who or what was involved, and how it ended. action recall finds episodes for a question (\"that recipe site\", \"what we decided about the logo\"); recent lists the latest; forget deletes one (by id from a result), the best matches for some words, or everything in a time. Use recall when the user refers to something from before (\"that site i was on\", \"what was i doing this morning\"), with times like yesterday in when, and answer from it in a sentence; use forget when they ask you to forget something.",
                parameters: [
                    "type": "OBJECT",
                    "properties": [
                        "action": [
                            "type": "STRING",
                            "enum": ["recall", "recent", "forget"],
                            "description": "recall (search), recent (list the latest), or forget."
                        ],
                        "query": [
                            "type": "STRING",
                            "description": "For recall or forget: a few words about it, like \"kaggle rank\" or \"site about lisbon flights\"."
                        ],
                        "when": [
                            "type": "STRING",
                            "description": "Optional time in plain words: today, this morning, yesterday, last night, tuesday, last week, 3 days ago, 2026-10-12."
                        ],
                        "id": [
                            "type": "STRING",
                            "description": "For forget: the #id shown in a recall or recent result."
                        ],
                        "count": [
                            "type": "INTEGER",
                            "description": "For recent: how many (default 8)."
                        ]
                    ],
                    "required": ["action"]
                ],
                run: { arguments in
                    let memory = DottieEpisodicMemory.shared
                    switch arguments.dottieString("action")?.lowercased() ?? "recall" {
                    case "recent", "list":
                        let count = arguments.dottieNumber("count").map { Int($0) } ?? 8
                        return memory.recentText(when: arguments.dottieString("when"), count: count)
                    case "forget", "delete":
                        return await memory.forgetText(
                            id: arguments.dottieString("id"),
                            query: arguments.dottieString("query"),
                            when: arguments.dottieString("when")
                        )
                    default:
                        let query = arguments.dottieString("query") ?? ""
                        let when = arguments.dottieString("when")
                        if query.isEmpty && when == nil {
                            return memory.recentText(when: nil, count: 8)
                        }
                        return await memory.recallText(query: query, when: when)
                    }
                }
            )
        ]
    }

    static var helperPromptSection: String {
        // Helpers don't get the memories tool (it's voice-only), so point
        // them at the files they can search themselves.
        "Dottie's episodic memory (what happened in past conversations, helper tasks, screen jobs and on screen, with when and where) is in \(DottieEpisodicMemory.shared.folderURL.path): episodes.jsonl, and index.json by day. Search those files when a task refers to something from before."
    }
}
