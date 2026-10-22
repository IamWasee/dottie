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
                description: "While you're playing a video game for the user, or mapping one while they play (a do_task_on_screen game job), pass what they tell the player, word for word: 'go left', 'jump', 'run', 'stop', 'grab that', 'go to the shop', 'this is the shop, remember it', 'in this game F opens the egg shop' (she presses the key to check and saves it), 'for this run, no jumping' (a rule for this run only), 'clear instructions', or 'done' to finish mapping. When she reads a plan back and asks for a go, the user's go or changes are the answer to her question, not a game_command. Everything the user says about the game while it's being played goes here, never to screenshots, notes or memory tools. Quick moves happen at once. Answer in two or three words, like 'on it'.",
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
                description: "Record the user playing a game (the screen plus every key, mouse button and mouse move, the same as Record gameplay in the menu bar) and play recordings back. start: 'record this', 'record me playing', 'record this as the sell loop' (put the name in name). stop: 'stop recording', or stop a recording being played back. play: 'do what I recorded', 'do the sell loop', 'replay that' (name, or empty for the newest): Dottie presses the same keys and moves the mouse the same way. list: which recordings there are. status: whether it's recording. open: show the recordings folder. Recordings are never deleted. Answer in a few words.",
                parameters: [
                    "type": "OBJECT",
                    "properties": [
                        "action": ["type": "STRING", "enum": ["start", "stop", "play", "list", "status", "open"], "description": "What to do."],
                        "name": ["type": "STRING", "description": "The recording's name, for start (to name it) and play (which one)."]
                    ],
                    "required": ["action"]
                ],
                audiences: [.voice]
            ) { arguments in
                let recorder = DottieGameplayRecorder.shared
                switch arguments.dottieString("action") ?? "status" {
                case "start":
                    guard !recorder.isRecording else { return "already recording." }
                    await recorder.startRecording(name: arguments.dottieString("name"))
                    if let problemMessage = recorder.problemMessage {
                        return "couldn't start: \(problemMessage)"
                    }
                    return recorder.isRecording ? "recording now. say stop recording when done." : "couldn't start recording."
                case "stop":
                    if DottieGameplayPlayback.shared.stop() {
                        return "stopped playing it back."
                    }
                    guard recorder.isRecording else { return "wasn't recording." }
                    recorder.stopRecording()
                    return "stopped. saved \(recorder.savedFrameCount) frames with the keys and mouse."
                case "play":
                    let spokenName = arguments.dottieString("name") ?? ""
                    guard let recording = DottieGameplayPlayback.recording(named: spokenName) else {
                        let names = DottieGameplayPlayback.savedRecordings().prefix(8).map(\.name)
                        return names.isEmpty
                            ? "there are no recordings yet. say record this to make one."
                            : "no recording matches \"\(spokenName)\". recordings: \(names.joined(separator: ", ")). ask which one."
                    }
                    return await DottieGameplayPlayback.shared.play(recording)
                case "list":
                    let recordings = DottieGameplayPlayback.savedRecordings().prefix(10)
                    guard !recordings.isEmpty else { return "no recordings yet." }
                    return recordings.map { "\($0.name) (\(Int($0.durationSeconds.rounded())) s)" }.joined(separator: "; ")
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
