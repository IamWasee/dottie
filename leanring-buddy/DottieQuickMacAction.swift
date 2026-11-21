//
//  DottieQuickMacAction.swift
//  leanring-buddy
//
//  quick_mac_action: the bigger models (voice Dottie, screen jobs) hand an
//  everyday Mac action ("open Spotify", "move this window left", "volume
//  30") to the instant lane and Needle, the on-Mac model, instead of doing
//  it by looking at screenshots. Done in well under a second with no AI
//  service; when neither knows it, the model is told to do it its own way.
//

import Foundation

/// Which instant-lane plans a model may run in the middle of its own work.
/// Foundation only, so it can be unit tested.
enum DottieQuickMacActionPlanKind: Equatable {
    case instantCommands
    case learnedShortcut
    case toolSteps
    /// Starts a whole screen job, which a running job must not do.
    case replayPhrase
    /// Saves a shortcut under the user's name for it: only the user asks for that.
    case saveNamedShortcut
    /// Starts or stops watching the user ("watch me", "done"): only the user asks for that.
    case learningPhrase

    var mayRunFromAModel: Bool {
        switch self {
        case .instantCommands, .learnedShortcut, .toolSteps: return true
        case .replayPhrase, .saveNamedShortcut, .learningPhrase: return false
        }
    }
}

@MainActor
enum DottieQuickMacAction {
    static let functionName = "quick_mac_action"

    /// Longest action text worth handing over; anything longer is a job,
    /// not one quick action.
    static let longestActionWordCount = 12

    static let toolDescription = "Do one everyday Mac action instantly on the Mac itself, with no screenshots: open or quit an app, move or fill a window, play/pause/skip music, set the volume, search Google or YouTube, press a named shortcut (\"new tab\", \"minimize\", \"command shift T\"), add a reminder or calendar event. Say it in a few plain words, like \"open Spotify\" or \"move this window left\". Use it in the middle of a bigger job whenever a step is one of these; if it answers that it couldn't, do that step your usual way."

    static var parameters: [String: Any] {
        [
            "type": "OBJECT",
            "properties": [
                "action": ["type": "STRING", "description": "The action in a few plain words: \"open Spotify\", \"quit Safari\", \"move this window to the left\", \"volume 30\", \"next song\"."]
            ],
            "required": ["action"]
        ]
    }

    static func kind(of plan: DottieInstantLane.Plan) -> DottieQuickMacActionPlanKind {
        switch plan {
        case .instantCommands: return .instantCommands
        case .learnedShortcut: return .learnedShortcut
        case .toolSteps: return .toolSteps
        case .replayPhrase: return .replayPhrase
        case .saveNamedShortcut: return .saveNamedShortcut
        case .learningPhrase: return .learningPhrase
        }
    }

    /// The action text to work with, or nil when it's empty or too long to
    /// be one quick action.
    static func usableActionText(_ arguments: [String: Any]) -> String? {
        guard let actionText = (arguments["action"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !actionText.isEmpty else { return nil }
        let wordCount = actionText.split(whereSeparator: { $0.isWhitespace }).count
        guard wordCount <= longestActionWordCount else { return nil }
        return actionText
    }

    /// What to tell the model after trying the action.
    static func perform(arguments: [String: Any]) async -> String {
        guard let actionText = usableActionText(arguments) else {
            return "error: give one short action, like \"open Spotify\". Do bigger steps your usual way."
        }
        // The strict instant lane first (exact, no model at all), then Needle.
        var foundPlan = DottieInstantLane.shared.plan(for: actionText)
        if foundPlan == nil {
            foundPlan = await DottieNeedleRouter.shared.plan(for: actionText)
        }
        guard let foundPlan, kind(of: foundPlan).mayRunFromAModel else {
            DottieLog.notice("⚡ quick_mac_action: no instant way, the model does it")
            return "couldn't do \"\(actionText)\" instantly. Do this step your usual way."
        }
        switch await DottieInstantLane.shared.run(foundPlan) {
        case .done(let doneText):
            DottieLog.notice("⚡ quick_mac_action done on the Mac")
            return "done on the Mac: \(doneText.isEmpty ? actionText : doneText) Carry on with the next step."
        case .askGemini:
            return "couldn't do \"\(actionText)\" instantly. Do this step your usual way."
        }
    }
}

/// quick_mac_action for voice Dottie.
enum DottieQuickMacActionTools: DottieToolModule {
    static var tools: [DottieTool] {
        [
            DottieTool(
                name: DottieQuickMacAction.functionName,
                description: DottieQuickMacAction.toolDescription,
                parameters: DottieQuickMacAction.parameters,
                run: { arguments in
                    await DottieQuickMacAction.perform(arguments: arguments)
                }
            )
        ]
    }

    static var voicePromptSection: String {
        "Quick Mac actions: when a step is opening or quitting an app, moving a window, music, volume, a Google/YouTube search, a named shortcut or a reminder, use quick_mac_action with a few plain words; it's instant and needs no screenshot."
    }
}
