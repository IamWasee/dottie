//
//  DottieSpeedTools.swift
//  leanring-buddy
//
//  Voice tools for the speed pack: `replays` (list, run or forget the
//  screen jobs Dottie can do from memory) and `self_check` (test
//  everything Dottie needs and say what's wrong).
//

import Foundation

@MainActor
enum DottieSpeedTools: DottieToolModule {
    /// Starts a saved replay as a screen job and returns the status for
    /// the voice. Set by CompanionManager.
    static var startReplayJob: ((DottieReplay) -> String)?

    static var tools: [DottieTool] {
        [
            DottieTool(
                name: "replays",
                description: "Screen jobs Dottie remembers and can redo instantly. list shows them, run starts one by name, forget deletes one.",
                parameters: [
                    "type": "OBJECT",
                    "properties": [
                        "action": ["type": "STRING", "enum": ["list", "run", "forget"]],
                        "name": ["type": "STRING", "description": "The replay's name or a few words of it (for run and forget)."]
                    ],
                    "required": ["action"]
                ],
                audiences: [.voice],
                run: { arguments in replays(arguments) }
            ),
            DottieTool(
                name: "self_check",
                description: "Tests everything Dottie needs (permissions, server, Gemini, voice, microphone, screen, helpers, phone) and returns what's wrong. Use when something seems broken.",
                audiences: [.voice],
                run: { _ in await DottieSelfCheck.shared.run() }
            )
        ]
    }

    static var voicePromptSection: String {
        """
        screen jobs that worked are remembered and redone instantly next time (no need to mention it unless asked). replays lists, runs or forgets them.
        if something seems broken (no sound, can't see the screen, slow answers), call self_check and tell the user the gist in a sentence or two.
        """
    }

    private static func replays(_ arguments: [String: Any]) -> String {
        let store = DottieReplayStore.shared
        switch arguments.dottieString("action")?.lowercased() ?? "list" {
        case "run":
            guard let name = arguments.dottieString("name"), let replay = store.replay(named: name) else {
                return "no saved replay matches that. call replays with action list to see them."
            }
            guard let startReplayJob else { return "replays can't run right now." }
            return "replaying \"\(replay.name)\": " + startReplayJob(replay)
        case "forget":
            guard let name = arguments.dottieString("name"), let replay = store.replay(named: name) else {
                return "no saved replay matches that."
            }
            store.forget(replay.id)
            return "forgot \"\(replay.name)\"."
        default:
            guard !store.replays.isEmpty else {
                return "no replays yet. any screen job that works is saved as one automatically."
            }
            let lines = store.replays.prefix(15).enumerated().map { index, replay in
                var line = "\(index + 1). \(replay.name) (\(replay.whereText), \(replay.steps.count) steps"
                if let seconds = replay.lastReplaySeconds { line += String(format: ", last took %.1fs", seconds) }
                return line + ")"
            }
            return "\(store.replays.count) saved:\n" + lines.joined(separator: "\n")
        }
    }
}
