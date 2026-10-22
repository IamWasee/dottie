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
                description: "Screen jobs that worked are remembered and redone instantly next time (no need to mention it unless asked). list shows them, numbered. run starts one by name, number ('the first replay') or shortcut phrase. forget deletes one. rename gives one a short name ('call it school fest'). shortcut saves a phrase that starts it ('when I say find me a school fest, run the first replay'): use this, not remember, for any 'when I say X, run/do replay Y'.",
                parameters: [
                    "type": "OBJECT",
                    "properties": [
                        "action": ["type": "STRING", "enum": ["list", "run", "forget", "rename", "shortcut"]],
                        "name": ["type": "STRING", "description": "Which replay: its name, a few words of it, or its number in the list."],
                        "new_name": ["type": "STRING", "description": "rename: the new short name."],
                        "phrase": ["type": "STRING", "description": "shortcut: what the user will say to start it, word for word."]
                    ],
                    "required": ["action"]
                ],
                audiences: [.voice],
                run: { arguments in replays(arguments) }
            ),
            DottieTool(
                name: "self_check",
                description: "Tests everything Dottie needs (permissions, server, Gemini, voice, microphone, screen, helpers, phone) and returns what's wrong. Use when something seems broken (no sound, can't see the screen, slow answers), then tell the user the gist in a sentence or two.",
                audiences: [.voice],
                run: { _ in await DottieSelfCheck.shared.run() }
            )
        ]
    }

    private static func replays(_ arguments: [String: Any]) -> String {
        let store = DottieReplayStore.shared
        switch arguments.dottieString("action")?.lowercased() ?? "list" {
        case "run":
            guard let name = arguments.dottieString("name"), let replay = store.replay(named: name) else {
                return "no saved replay matches that. call replays with action list to see them."
            }
            guard let startReplayJob else { return "replays can't run right now." }
            return "replay \"\(replay.name)\": " + startReplayJob(replay)
        case "rename":
            guard let name = arguments.dottieString("name"), let replay = store.replay(named: name) else {
                return "no saved replay matches that. call replays with action list to see them."
            }
            guard let newName = arguments.dottieString("new_name") else { return "say what to call it." }
            store.rename(replay.id, to: newName)
            return "renamed \"\(replay.name)\" to \"\(newName)\"."
        case "shortcut":
            guard let name = arguments.dottieString("name"), let replay = store.replay(named: name) else {
                return "no saved replay matches that. call replays with action list to see them."
            }
            guard let phrase = arguments.dottieString("phrase") else { return "say which phrase should start it." }
            store.addVoiceShortcut(phrase, to: replay.id)
            return "saved: saying \"\(phrase)\" now runs \"\(replay.name)\". it works from the next conversation on."
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
