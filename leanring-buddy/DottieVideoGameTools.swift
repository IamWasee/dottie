//
//  DottieVideoGameTools.swift
//  leanring-buddy
//
//  Co-op while Dottie plays a video game: what the user says to the player
//  mid-game ("go left", "jump", "grab that") reaches it right away. Quick
//  calls act on the next frame; the rest go to the game brain. Also the
//  saved game maps: list them, show one in Finder, or delete one.
//

import Foundation

enum DottieVideoGameTools: DottieToolModule {
    static var tools: [DottieTool] {
        [
            DottieTool(
                name: "game_command",
                description: "While you're playing a video game for the user, or mapping one while they play (a do_task_on_screen game job), pass what they tell the player, word for word: 'go left', 'jump', 'run', 'stop', 'grab that', 'go to the shop', or 'done' to finish mapping. Quick moves happen at once. Answer in two or three words, like 'on it'.",
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
            },
            DottieTool(
                name: "game_maps",
                description: "Dottie's saved 3D maps of video games. list: which games have a map and how big. open: show a game's map picture and report in Finder (or every map with no game). delete: erase a game's map so it's mapped from scratch next time; only when the user asks to delete it, and the user confirms on screen. Deleting keeps the game's notebook and gameplay recordings.",
                parameters: [
                    "type": "OBJECT",
                    "properties": [
                        "action": ["type": "STRING", "enum": ["list", "open", "delete"], "description": "What to do."],
                        "game": ["type": "STRING", "description": "The game's name as the user said it. Needed for delete."]
                    ],
                    "required": ["action"]
                ],
                audiences: [.voice]
            ) { arguments in
                let spokenGameName = arguments.dottieString("game") ?? ""
                switch arguments.dottieString("action") ?? "list" {
                case "open":
                    let savedMap = spokenGameName.isEmpty ? nil : DottieGameMapPicture.savedMap(named: spokenGameName)
                    DottieGameMapPicture.openInFinder(savedMap)
                    if !spokenGameName.isEmpty, savedMap == nil {
                        return "there's no map of \(spokenGameName); opened the folder with every game's map instead."
                    }
                    return "opened in Finder."
                case "delete":
                    guard let savedMap = DottieGameMapPicture.savedMap(named: spokenGameName) else {
                        let mapNames = DottieGameMapPicture.savedMaps().map(\.gameName)
                        return mapNames.isEmpty
                            ? "there are no saved game maps."
                            : "no map matches \"\(spokenGameName)\". saved maps: \(mapNames.joined(separator: ", ")). ask which one."
                    }
                    if let gamePlayer = DottieGamePlayer.current, gamePlayer.currentGameName == savedMap.gameName {
                        return "\(savedMap.gameName) is being played right now; stop the game first, then delete its map."
                    }
                    let isConfirmed = DottieConfirmation.ask(
                        title: "Delete the map of \(savedMap.gameName)?",
                        detail: "Dottie forgets the \(savedMap.spotCount) spots she mapped and maps the game again next time. The game's notes and your gameplay recordings stay.",
                        confirmButtonTitle: "Delete map"
                    )
                    guard isConfirmed else { return "the user chose not to delete it." }
                    return DottieGameMapPicture.deleteMap(savedMap)
                        ? "deleted the map of \(savedMap.gameName)."
                        : "couldn't delete the map of \(savedMap.gameName)."
                default:
                    let maps = DottieGameMapPicture.savedMaps()
                    guard !maps.isEmpty else { return "no game has a map yet." }
                    return maps.map { "\($0.gameName): \($0.spotCount) spots" }.joined(separator: "; ")
                }
            }
        ]
    }
}
