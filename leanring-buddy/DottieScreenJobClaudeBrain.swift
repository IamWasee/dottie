//
//  DottieScreenJobClaudeBrain.swift
//  leanring-buddy
//
//  Screen jobs think with Claude Sonnet first, through the user's Claude
//  plan in MausBot (bot "Dottie Screen Jobs"), and Gemini Flash takes over
//  when Claude isn't there or doesn't answer in time. The runner
//  (DottieScreenTaskRunner) keeps one Gemini-shaped conversation either
//  way, so the switch can happen at any step:
//
//    - Each step, the runner's newest turn (results of the last actions, a
//      fresh screenshot, maybe a zoomed crop, and the step's notes) is
//      written out as one message: the pictures as files Claude opens.
//    - Claude has the same instructions and the same actions Gemini gets
//      (as JSON in its standing instructions) and answers with JSON:
//      {"actions": [{"name": "click", "args": {"box_px": [...], "label": "Send"}}]}
//    - Boxes come in pixels of the screenshot ([left, top, right, bottom]),
//      which is how Claude measures best, and are turned into Gemini's
//      0-1000 [ymin, xmin, ymax, xmax] here, so the runner reads one format.
//    - The answer becomes function-call parts, with Google's placeholder
//      thought signature, so Gemini can carry on the same history later.
//
//  The first step of a job starts a new conversation; later steps continue
//  it, so Claude remembers what it already saw. Once Claude misses a step,
//  the rest of that job stays on Gemini (Claude would be missing steps).
//  Settings → Speed can turn Claude off for screen jobs.
//

import CoreGraphics
import Foundation

@MainActor
final class DottieScreenJobClaudeBrain {
    static let shared = DottieScreenJobClaudeBrain()

    nonisolated static let isEnabledDefaultsKey = "dottieScreenJobsUseClaude"
    /// On unless the user turned it off.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: isEnabledDefaultsKey) as? Bool ?? true
    }

    /// Sonnet looking at a screenshot usually answers in 4-15 s. Round 1
    /// testing saw a 36 s wait before step 1, so after this the job moves
    /// to Gemini/Groq (one miss already moves the rest of the job there).
    private static let stepTimeoutSeconds: Double = 20
    private static let placeholderThoughtSignature = "skip_thought_signature_validator"

    private var bot: DottieClaudeBot?
    private var botInstructionsKey = ""
    private var stepPictureCount = 0

    func stop() {
        bot?.stop()
    }

    var isWorthTrying: Bool {
        Self.isEnabled && (bot?.isWorthTrying ?? true)
    }

    /// Claude's next actions as Gemini parts, or nil to ask Gemini instead.
    /// - newestTurnParts: the runner's newest user turn (function responses,
    ///   the screenshot as inlineData, extra pictures, notes).
    /// - referenceImageParts: pictures the user saved that the job is about,
    ///   sent with the first step.
    func nextActions(
        newestTurnParts: [[String: Any]],
        isFirstStepOfJob: Bool,
        systemInstruction: String,
        functionDeclarations: [[String: Any]],
        screenshotPixelSize: CGSize,
        referenceImageParts: [[String: Any]]
    ) async -> [[String: Any]]? {
        guard Self.isEnabled, screenshotPixelSize.width > 0, screenshotPixelSize.height > 0 else { return nil }
        let claudeBot = bot(systemInstruction: systemInstruction, functionDeclarations: functionDeclarations)
        guard claudeBot.isWorthTrying else { return nil }
        if isFirstStepOfJob {
            clearOldPictures(in: claudeBot.workspaceURL)
        }

        var messageLines: [String] = []
        var savedScreenshot = false
        if isFirstStepOfJob {
            for (index, part) in referenceImageParts.enumerated() {
                if let text = part["text"] as? String {
                    messageLines.append(text)
                } else if let pictureURL = savePicture(part, in: claudeBot.workspaceURL, name: "reference-\(index)") {
                    messageLines.append("That reference picture is `\(pictureURL.path)` (open it).")
                }
            }
        }
        for part in newestTurnParts {
            if let functionResponse = part["functionResponse"] as? [String: Any] {
                let actionName = functionResponse["name"] as? String ?? "action"
                let result = (functionResponse["response"] as? [String: Any])?["result"] as? String ?? ""
                messageLines.append("Result of \(actionName): \(result)")
            } else if part["inlineData"] != nil {
                if !savedScreenshot, let screenshotURL = savePicture(part, in: claudeBot.workspaceURL, name: "screen") {
                    savedScreenshot = true
                    messageLines.append("The screen now: open `\(screenshotURL.path)` first. It is \(Int(screenshotPixelSize.width))x\(Int(screenshotPixelSize.height)) pixels.")
                } else if let extraURL = savePicture(part, in: claudeBot.workspaceURL, name: "extra") {
                    messageLines.append("Another picture for this step (a zoomed part or a look around, not for measuring boxes): `\(extraURL.path)`.")
                }
            } else if let text = part["text"] as? String {
                messageLines.append(text)
            }
        }
        guard savedScreenshot else { return nil }
        messageLines.append("Reply with only the JSON object of your next actions. Boxes in pixels of that \(Int(screenshotPixelSize.width))x\(Int(screenshotPixelSize.height)) screenshot as [left, top, right, bottom].")

        guard let replyText = await claudeBot.send(messageLines.joined(separator: "\n\n"), newConversation: isFirstStepOfJob, timeoutSeconds: Self.stepTimeoutSeconds),
              let reply = DottieClaudeBot.jsonObject(in: replyText),
              let rawActions = reply["actions"] as? [[String: Any]], !rawActions.isEmpty else {
            return nil
        }
        let knownActionNames = Set(functionDeclarations.compactMap { $0["name"] as? String })
        let parts: [[String: Any]] = rawActions.compactMap { rawAction in
            guard let actionName = rawAction["name"] as? String, knownActionNames.contains(actionName) else { return nil }
            let rawArguments = rawAction["args"] as? [String: Any] ?? [:]
            let functionCall: [String: Any] = [
                "name": actionName,
                "args": Self.argumentsWithGeminiBoxes(rawArguments, screenshotPixelSize: screenshotPixelSize)
            ]
            return ["functionCall": functionCall, "thoughtSignature": Self.placeholderThoughtSignature]
        }
        return parts.isEmpty ? nil : parts
    }

    /// box_px, player_box_px, target_box_px ([left, top, right, bottom] in
    /// pixels) become box_2d, player_box_2d, target_box_2d ([ymin, xmin,
    /// ymax, xmax] in 0-1000). A box already in 0-1000 is kept as is.
    static func argumentsWithGeminiBoxes(_ arguments: [String: Any], screenshotPixelSize: CGSize) -> [String: Any] {
        var convertedArguments: [String: Any] = [:]
        for (key, value) in arguments {
            guard key.hasSuffix("_px") else {
                convertedArguments[key] = value
                continue
            }
            let numbers = (value as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
            guard numbers.count == 4 else { continue }
            let (left, top, right, bottom) = (min(numbers[0], numbers[2]), min(numbers[1], numbers[3]), max(numbers[0], numbers[2]), max(numbers[1], numbers[3]))
            func scaledX(_ pixelX: Double) -> Double { min(max(pixelX / Double(screenshotPixelSize.width) * 1000, 0), 1000) }
            func scaledY(_ pixelY: Double) -> Double { min(max(pixelY / Double(screenshotPixelSize.height) * 1000, 0), 1000) }
            let baseName = String(key.dropLast(3))
            convertedArguments[baseName + "_2d"] = [scaledY(top), scaledX(left), scaledY(bottom), scaledX(right)]
        }
        return convertedArguments
    }

    // MARK: - The bot

    private func bot(systemInstruction: String, functionDeclarations: [[String: Any]]) -> DottieClaudeBot {
        let declarationsText = (try? JSONSerialization.data(withJSONObject: functionDeclarations, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        let instructions = systemInstruction + "\n\n" + Self.claudeFormatInstructions + "\n\nThe actions you can take (the same as function declarations, with each box_2d given instead as box_px in pixels, player_box_2d as player_box_px and target_box_2d as target_box_px):\n" + declarationsText
        if let bot, botInstructionsKey == instructions { return bot }
        let newBot = DottieClaudeBot(
            helperName: "Dottie Screen Jobs",
            title: "Does jobs on the user's screen, a step at a time",
            instructions: instructions,
            folderName: "ScreenJobs",
            agentID: UUID(uuidString: "2B7E4C1A-9D3F-4E6A-8B5C-1F2A3D4E5F60") ?? UUID()
        )
        bot = newBot
        botInstructionsKey = instructions
        return newBot
    }

    private static let claudeFormatInstructions = """
    How this works with you: each message gives the screen as a screenshot file to open, the results of your last actions, and notes. Open the screenshot and look carefully before answering; zoom into small text when you need to. You know most apps and websites well (where their menus, buttons and shortcuts are), so use that, but only click what you can see on this screenshot.

    Reply with only a JSON object, no other text:
    {"actions": [{"name": "<action>", "args": {...}}]}
    One to three actions per reply, in order. Boxes: measure on the screenshot itself, in its pixels, as [left, top, right, bottom], under box_px (instead of box_2d). A click box hugs that one control. Every action needs the arguments its declaration requires. Finish with the finish action when the task is done or truly can't be done.
    """

    // MARK: - Pictures as files

    private func savePicture(_ part: [String: Any], in folderURL: URL, name: String) -> URL? {
        guard let inlineData = part["inlineData"] as? [String: Any],
              let base64Text = inlineData["data"] as? String,
              let pictureData = Data(base64Encoded: base64Text) else { return nil }
        stepPictureCount += 1
        // A new name each step, so Claude never reads an older picture
        // from its cache.
        let pictureURL = folderURL.appendingPathComponent("\(name)-\(stepPictureCount).jpg")
        guard (try? pictureData.write(to: pictureURL, options: .atomic)) != nil else { return nil }
        return pictureURL
    }

    private func clearOldPictures(in folderURL: URL) {
        let fileURLs = (try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)) ?? []
        for fileURL in fileURLs where fileURL.pathExtension == "jpg" {
            try? FileManager.default.removeItem(at: fileURL)
        }
        stepPictureCount = 0
    }
}
