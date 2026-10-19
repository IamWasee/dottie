//
//  DottieVideoGameTools.swift
//  leanring-buddy
//
//  Co-op while Dottie plays a video game: what the user says to the player
//  mid-game ("go left", "jump", "grab that") reaches it right away. Quick
//  calls act on the next frame; the rest go to the game brain.
//

import Foundation

enum DottieVideoGameTools: DottieToolModule {
    static var tools: [DottieTool] {
        [
            DottieTool(
                name: "game_command",
                description: "While you're playing a video game for the user (a do_task_on_screen game job), pass what they tell the player, word for word: 'go left', 'jump', 'run', 'stop', 'grab that', 'go to the shop'. Quick moves happen at once. Answer in two or three words, like 'on it'.",
                parameters: [
                    "type": "OBJECT",
                    "properties": [
                        "command": ["type": "STRING", "description": "What the user said to the player, word for word."]
                    ],
                    "required": ["command"]
                ],
                audiences: [.voice]
            ) { arguments in
                guard let gamePlayer = DottieGamePlayer.current else {
                    return "no game is being played right now. to play one, use do_task_on_screen with game true."
                }
                gamePlayer.receiveUserCommand(arguments.dottieString("command") ?? "")
                return "passed to the player."
            }
        ]
    }
}
