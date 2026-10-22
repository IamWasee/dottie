//
//  DottieVideoGameTools.swift
//  leanring-buddy
//
//  Co-op while Dottie plays a video game: what the user says to the player
//  mid-game ("go left", "jump", "grab that") reaches it right away. Quick
//  calls act on the next frame; the rest go to the game brain. Also the
//  saved game maps (list them, show one in Finder, or delete one) and
//  recording gameplay by voice.
//

import Foundation

enum DottieVideoGameTools: DottieToolModule {
    static var tools: [DottieTool] {
        [
            DottieTool(
                name: "game_command",
                description: "While you're playing a video game for the user, or mapping one while they play (a do_task_on_screen game job), pass what they tell the player, word for word: 'go left', 'jump', 'run', 'stop', 'grab that', 'go to the shop', 'this is the shop, remember it', 'in this game F opens the egg shop' (she presses the key to check and saves it), or 'done' to finish mapping. Everything the user says about the game while it's being played goes here, never to screenshots, notes or memory tools. Quick moves happen at once. Answer in two or three words, like 'on it'.",
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
                name: "gameplay_recording",
                description: "Record the user playing a game: the screen plus every key, mouse button and mouse move, saved as gameplay data (the same as Record gameplay in the menu bar). start: when they say 'record this', 'record me playing', 'start recording'. stop: 'stop recording', 'that's it'. status: whether it's recording and how much it saved. open: show the recordings folder. Recordings are never deleted. Answer in a few words.",
                parameters: [
                    "type": "OBJECT",
                    "properties": [
                        "action": ["type": "STRING", "enum": ["start", "stop", "status", "open"], "description": "What to do."]
                    ],
                    "required": ["action"]
                ],
                audiences: [.voice]
            ) { arguments in
                let recorder = DottieGameplayRecorder.shared
                switch arguments.dottieString("action") ?? "status" {
                case "start":
                    guard !recorder.isRecording else { return "already recording." }
                    await recorder.startRecording()
                    if let problemMessage = recorder.problemMessage {
                        return "couldn't start: \(problemMessage)"
                    }
                    return recorder.isRecording ? "recording now. say stop recording when done." : "couldn't start recording."
                case "stop":
                    guard recorder.isRecording else { return "wasn't recording." }
                    recorder.stopRecording()
                    return "stopped. saved \(recorder.savedFrameCount) frames with the keys and mouse."
                case "open":
                    recorder.openGameDataFolder()
                    return "opened the recordings folder in Finder."
                default:
                    return recorder.isRecording
                        ? "recording: \(recorder.savedFrameCount) frames so far."
                        : "not recording."
                }
            },
            DottieTool(
                name: "game_maps",
                description: "Dottie's saved 3D maps of video games. list: which games have a map and how big. open: show a game's map picture and report in Finder (or every map with no game). open_3d: open a game's map as a 3D model the user can turn around. delete: erase a game's map so it's mapped from scratch next time; only when the user asks to delete it, and the user confirms on screen. Deleting keeps the game's notebook and gameplay recordings.",
                parameters: [
                    "type": "OBJECT",
                    "properties": [
                        "action": ["type": "STRING", "enum": ["list", "open", "open_3d", "delete"], "description": "What to do."],
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
                case "open_3d":
                    guard let savedMap = DottieGameMapPicture.savedMap(named: spokenGameName) else {
                        let mapNames = DottieGameMapPicture.savedMaps().map(\.gameName)
                        return mapNames.isEmpty
                            ? "there are no saved game maps."
                            : "no map matches \"\(spokenGameName)\". saved maps: \(mapNames.joined(separator: ", ")). ask which one."
                    }
                    return await DottieGameMapPicture.open3DModel(savedMap)
                        ? "opened the 3D map of \(savedMap.gameName). drag in it to turn it around."
                        : "couldn't make a 3D model of \(savedMap.gameName)'s map."
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
