//
//  DottieEpisodicMemoryTools.swift
//  leanring-buddy
//
//  The memories tool, for voice Dottie and her helpers: look things up in
//  the episodic memory ("that site I was on", "what did we talk about
//  yesterday"), list what happened lately, or forget something; open the
//  picture an episode kept; and list, add or forget the user's routines
//  (DottieHabits).
//

import AppKit
import Foundation

@MainActor
enum DottieEpisodicMemoryTools: DottieToolModule {
    static var tools: [DottieTool] {
        [
            DottieTool(
                name: "memories",
                description: "Dottie's memory of what happened: conversations with the user, what helpers and screen jobs did, and (if the user turned it on) what was on their screen. Each episode has when, where (app, window, web page), who or what was involved, and how it ended. action recall finds episodes for a question (\"that recipe site\", \"what we decided about the logo\"); recent lists the latest; forget deletes one (by id from a result), the best matches for some words, or everything in a time. Episodes keep a picture of what was on screen, described in words, so recall also finds things by how they looked (\"that blue sofa i was looking at\"); show opens an episode's picture on screen (by id or words). routines lists the user's routines (what they do at about the same time most days, noticed on the Mac, and ones they told you); add_routine saves one they tell you (\"i go to the gym mondays at 6\": text is what, when is the days and time); forget_routine removes one (id or words). Use recall when the user refers to something from before (\"that site i was on\", \"what was i doing this morning\"), with times like yesterday in when, and answer from it in a sentence; use forget when they ask you to forget something.",
                parameters: [
                    "type": "OBJECT",
                    "properties": [
                        "action": [
                            "type": "STRING",
                            "enum": ["recall", "recent", "forget", "show", "routines", "add_routine", "forget_routine"],
                            "description": "recall (search), recent (list the latest), forget, show (open an episode's picture), routines (list), add_routine or forget_routine."
                        ],
                        "query": [
                            "type": "STRING",
                            "description": "For recall or forget: a few words about it, like \"kaggle rank\" or \"site about lisbon flights\"."
                        ],
                        "text": [
                            "type": "STRING",
                            "description": "For add_routine: what they do, in a few words, like \"goes to the gym\"."
                        ],
                        "when": [
                            "type": "STRING",
                            "description": "For add_routine: when, like \"mondays at 6pm\" or \"every morning\". Otherwise an optional time in plain words: today, this morning, yesterday, last night, tuesday, last week, 3 days ago, 2026-10-12."
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
                    case "show", "open":
                        return await showPicture(
                            id: arguments.dottieString("id"),
                            query: arguments.dottieString("query"),
                            when: arguments.dottieString("when")
                        )
                    case "routines", "habits":
                        DottieHabits.shared.findRoutines()
                        return DottieHabits.shared.listText
                    case "add_routine":
                        guard let text = arguments.dottieString("text") ?? arguments.dottieString("query"),
                              let habit = DottieHabits.shared.addToldRoutine(text, when: arguments.dottieString("when")) else {
                            return "say what the routine is in text, and when."
                        }
                        return "saved the routine: \(habit.sentence)."
                    case "forget_routine":
                        guard let reference = arguments.dottieString("id") ?? arguments.dottieString("query") ?? arguments.dottieString("text"),
                              let habit = DottieHabits.shared.habit(matching: reference) else {
                            return "no routine like that. " + DottieHabits.shared.listText
                        }
                        DottieHabits.shared.forget(habit)
                        return "forgot the routine: \(habit.sentence)."
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

    /// Opens the picture an episode kept, found by id or words.
    private static func showPicture(id: String?, query: String?, when: String?) async -> String {
        let memory = DottieEpisodicMemory.shared
        var candidates: [DottieEpisode] = []
        if let id = id?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "# ")), !id.isEmpty {
            candidates = memory.episodes.filter { $0.shortID == id }
        } else if let query, !query.isEmpty {
            candidates = await memory.recall(query: query, when: when, limit: 6).episodes
        } else {
            candidates = Array(memory.episodes.reversed())
        }
        guard let episode = candidates.first(where: { memory.thumbnailURL(for: $0) != nil }),
              let pictureURL = memory.thumbnailURL(for: episode) else {
            return candidates.isEmpty ? "found nothing like that." : "found it, but no picture was kept for it."
        }
        NSWorkspace.shared.open(pictureURL)
        return "opened the picture from \"\(episode.title)\" on screen." + (episode.pictureDescription.map { " it shows: \($0)" } ?? "")
    }

    static var helperPromptSection: String {
        // Helpers don't get the memories tool (it's voice-only), so point
        // them at the files they can search themselves.
        "Dottie's episodic memory (what happened in past conversations, helper tasks, screen jobs and on screen, with when and where) is in \(DottieEpisodicMemory.shared.folderURL.path): episodes.jsonl, and index.json by day. Search those files when a task refers to something from before. Pictures of what was on screen are in its Thumbnails folder (named by episode id), and the user's routines are in habits.json."
    }
}
