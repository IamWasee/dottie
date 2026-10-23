//
//  DottieGuideBrain.swift
//  leanring-buddy
//
//  Guides think with Claude Sonnet first, through the user's Claude plan in
//  MausBot (its own bot, "Dottie Guide"), and fall back to Gemini Flash
//  only when Claude isn't there or doesn't answer in time. Gemini Flash
//  answered "where do I isolate the audio in CapCut" with a button CapCut
//  doesn't have; Sonnet reads screenshots more carefully, checks the app's
//  help pages itself, and says when it isn't sure.
//
//  The screenshot is saved as a file the bot opens, and each step is a new
//  conversation: the guide's history already travels in the message, and
//  old screenshots would only slow it down.
//

import CoreGraphics
import Foundation

@MainActor
final class DottieGuideBrain {
    static let shared = DottieGuideBrain()

    private let mausBotRuntime = DottieMausBotRuntime()
    private static let guideAgentID = UUID(uuidString: "8C5A1B3E-6D4F-4A0C-9E2B-3F4A5B6C7D8E") ?? UUID()
    /// Sonnet looking at a screenshot (and maybe the app's help pages)
    /// usually answers in 5-15 s.
    private static let claudeAnswerTimeoutSeconds: Double = 35
    /// After Claude failed, guides use Gemini until this time.
    private var claudeSkippedUntil: Date?
    private(set) var lastEngineName = "claude"

    private static let botIDDefaultsKey = "dottieGuideBotID"
    private static let botNameDefaultsKey = "dottieGuideBotName"
    private static let botSpecHashDefaultsKey = "dottieGuideBotSpecHash"

    private let workspaceURL: URL = {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folderURL = applicationSupportURL.appendingPathComponent("Dottie/Guide", isDirectory: true)
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        return folderURL
    }()

    func stop() {
        mausBotRuntime.stopTurn(agentID: Self.guideAgentID)
    }

    /// Claude's JSON answer for this step, or nil to ask Gemini instead.
    /// Claude gives boxes in pixels of the screenshot (what it's trained
    /// on); they're turned into Gemini's 0-1000 boxes here, so the rest of
    /// the guide reads one format. Asking Claude for 0-1000 boxes made it
    /// convert by hand and land the pointer off target.
    func askClaude(systemInstruction: String, stepInstruction: String, screenshotJPEG: Data, screenshotPixelSize: CGSize) async -> String? {
        if let claudeSkippedUntil, claudeSkippedUntil > Date() { return nil }
        guard case .ready(let launcher) = await DottieMausBot.shared.readinessForHelperTurn() else { return nil }

        let screenshotURL = workspaceURL.appendingPathComponent("screen.jpg")
        guard (try? screenshotJPEG.write(to: screenshotURL, options: .atomic)) != nil else { return nil }

        let sonnetModelSelection = await DottieMausBot.shared.modelSelection(matching: "sonnet", launcher: launcher)
        let defaults = UserDefaults.standard
        let spec = DottieMausBotSpec(
            helperName: "Dottie Guide",
            title: "Teaches the user their apps on screen",
            instructions: systemInstruction + "\n\n" + Self.claudeExtraInstructions,
            workspacePath: workspaceURL.path,
            skillFiles: [],
            effort: "low",
            knownBotID: defaults.string(forKey: Self.botIDDefaultsKey),
            knownBotName: defaults.string(forKey: Self.botNameDefaultsKey),
            knownSpecHash: defaults.string(forKey: Self.botSpecHashDefaultsKey),
            model: sonnetModelSelection
        )
        let identity: DottieMausBotIdentity
        switch await mausBotRuntime.ensureBot(for: spec, launcher: launcher) {
        case .failure(let reason):
            print("⚠️ Guide: Claude bot not ready (\(reason)), using Gemini")
            skipClaudeForAWhile()
            return nil
        case .success(let readyIdentity):
            identity = readyIdentity
        }
        defaults.set(identity.botID, forKey: Self.botIDDefaultsKey)
        defaults.set(identity.botName, forKey: Self.botNameDefaultsKey)
        defaults.set(identity.specHash, forKey: Self.botSpecHashDefaultsKey)

        let replyCollector = DottieGameReplyCollector()
        let runtime = mausBotRuntime
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.claudeAnswerTimeoutSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            runtime.stopTurn(agentID: Self.guideAgentID)
        }
        let claudeStartedAt = Date()
        let screenshotWidth = Int(screenshotPixelSize.width)
        let screenshotHeight = Int(screenshotPixelSize.height)
        let message = "Open the screenshot of the user's screen first: `\(screenshotURL.path)`. It is \(screenshotWidth)x\(screenshotHeight) pixels.\n\n" + stepInstruction
            + "\n\nGive every box in pixels of that \(screenshotWidth)x\(screenshotHeight) screenshot as [left, top, right, bottom] (target_box_px, box_px), not 0-1000. Reply with only the JSON object."
        let outcome = await mausBotRuntime.runTurn(
            agentID: Self.guideAgentID,
            botID: identity.botID,
            message: message,
            conversation: "new",
            launcher: launcher,
            onConversationStarted: { _ in }
        ) { event in
            if case .assistantTextDelta(let textDelta) = event {
                replyCollector.text += textDelta
            }
        }
        timeoutTask.cancel()
        DottieUsage.shared.record(area: .pointing, inputTokens: 0, outputTokens: 0, seconds: Date().timeIntervalSince(claudeStartedAt))

        switch outcome {
        case .finished(let succeeded, _) where succeeded && replyCollector.text.contains("{"):
            guard let convertedReply = Self.replyWithGeminiBoxes(
                fromPixelBoxReply: replyCollector.text,
                screenshotPixelSize: screenshotPixelSize
            ) else {
                print("⚠️ Guide: Claude's answer wasn't readable JSON, using Gemini for this step")
                return nil
            }
            lastEngineName = "claude"
            return convertedReply
        case .stopped:
            print("⚠️ Guide: Claude took over \(Int(Self.claudeAnswerTimeoutSeconds)) s, using Gemini for this step")
            return nil
        default:
            skipClaudeForAWhile()
            return nil
        }
    }

    /// Rewrites Claude's pixel boxes ([left, top, right, bottom] under
    /// target_box_px and box_px) as the guide's [ymin, xmin, ymax, xmax]
    /// 0-1000 boxes (target_box, box_2d). A 0-1000 box Claude gave anyway
    /// is kept as it is.
    static func replyWithGeminiBoxes(fromPixelBoxReply replyText: String, screenshotPixelSize: CGSize) -> String? {
        guard screenshotPixelSize.width > 0, screenshotPixelSize.height > 0,
              let jsonStart = replyText.firstIndex(of: "{"), let jsonEnd = replyText.lastIndex(of: "}"),
              let replyData = String(replyText[jsonStart...jsonEnd]).data(using: .utf8),
              var reply = try? JSONSerialization.jsonObject(with: replyData) as? [String: Any],
              let rawSteps = reply["steps"] as? [[String: Any]] else { return nil }

        func geminiBox(fromPixelBox pixelBox: Any?) -> [Double]? {
            let numbers = (pixelBox as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
            guard numbers.count == 4 else { return nil }
            let (left, top, right, bottom) = (numbers[0], numbers[1], numbers[2], numbers[3])
            guard right >= left, bottom >= top else { return nil }
            func scaledX(_ pixelX: Double) -> Double { min(max(pixelX / Double(screenshotPixelSize.width) * 1000, 0), 1000) }
            func scaledY(_ pixelY: Double) -> Double { min(max(pixelY / Double(screenshotPixelSize.height) * 1000, 0), 1000) }
            return [scaledY(top), scaledX(left), scaledY(bottom), scaledX(right)]
        }
        func convertingBox(in object: [String: Any], pixelKey: String, geminiKey: String) -> [String: Any] {
            var convertedObject = object
            if let convertedBox = geminiBox(fromPixelBox: object[pixelKey]) {
                convertedObject[geminiKey] = convertedBox
            }
            convertedObject.removeValue(forKey: pixelKey)
            return convertedObject
        }

        reply["steps"] = rawSteps.map { rawStep -> [String: Any] in
            var convertedStep = convertingBox(in: rawStep, pixelKey: "target_box_px", geminiKey: "target_box")
            if let rawMarks = rawStep["marks"] as? [[String: Any]] {
                convertedStep["marks"] = rawMarks.map { convertingBox(in: $0, pixelKey: "box_px", geminiKey: "box_2d") }
            }
            if let rawReveal = rawStep["reveal"] as? [String: Any] {
                convertedStep["reveal"] = convertingBox(in: rawReveal, pixelKey: "box_px", geminiKey: "box_2d")
            }
            return convertedStep
        }
        guard let convertedData = try? JSONSerialization.data(withJSONObject: reply) else { return nil }
        return String(decoding: convertedData, as: UTF8.self)
    }

    private func skipClaudeForAWhile() {
        claudeSkippedUntil = Date().addingTimeInterval(120)
        lastEngineName = "gemini"
    }

    /// The answer's shape, which Gemini gets as a response schema.
    private static let claudeExtraInstructions = """
    You get one screenshot per message, as a file to open, and its size in pixels. Look at it carefully before answering; zoom into small text if you need to. If you're not sure how this app does something, look it up in the app's own help pages or a recent guide for it before answering (keep that quick: the user is waiting). Never invent a button, menu or panel: only point at what you can see on the screenshot.

    Boxes: ignore the 0-1000 box_2d format described above. Give every box in pixels of the screenshot as [left, top, right, bottom], under target_box_px (instead of target_box) and box_px (instead of box_2d). Measure on the image itself; don't convert anything. A click target's box hugs that one control (a button or tab is usually under 250 pixels wide), never its whole row or toolbar, and target_label is its exact visible text.

    Reply with only a JSON object, no other text:
    {"steps": [{"kind": "click" | "look" | "done", "say": "...", "target_box_px": [left, top, right, bottom], "target_label": "exact visible text", "marks": [{"shape": "circle" | "box" | "underline" | "arrow" | "highlight", "box_px": [left, top, right, bottom], "note": "1-3 words"}], "reveal": {"action": "scroll" | "click" | "keys", "box_px": [left, top, right, bottom], "direction": "up" | "down" | "left" | "right", "keys": "cmd+shift+e"}}]}
    Only "kind" and "say" are required; leave the others out when they don't apply.
    """
}
