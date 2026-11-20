//
//  DottieVideoGameTools.swift
//  leanring-buddy
//
//  Recording gameplay by voice: start (with a name), stop, play a
//  recording back, list them and open their folder. Recordings are never
//  deleted.
//

import Foundation

enum DottieVideoGameTools: DottieToolModule {
    static var tools: [DottieTool] {
        [
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
            }
        ]
    }
}
