//
//  DottieWatchAndLearn.swift
//  leanring-buddy
//
//  Watch and learn: "watch me do this for 30 seconds". While the user works,
//  Dottie keeps a frame of the screen every two seconds and the clicks,
//  typing and app switches the smart-replay recorder already notices (no
//  passwords). At the end Claude (Gemini when Claude isn't there) looks at
//  the frames and the actions and writes down, in words, what the user was
//  doing and how: the goal, the method in general steps, where things are
//  in that app, and what would change for a similar job. Not the exact
//  clicks: the understanding, so "do the same for the March sheet" or
//  "make a table like that for the other database" works too.
//
//  Each how-to is kept in Application Support/Dottie/Watched/howtos.json
//  and saved as a skill in the skills library (turned on for every Dot),
//  so screen jobs (DottieScreenTaskRunner and its guesser) and helpers both
//  use it on similar tasks.
//

import AppKit
import Combine
import Foundation

struct DottieWatchedHowTo: Codable, Identifiable, Equatable {
    var id = UUID()
    let learnedAt: Date
    var name: String
    var appName: String
    var summary: String
    var goal: String
    var method: [String]
    var interfaceNotes: [String]
    var worksFor: String
    var skillName: String?

    /// What a screen job or helper is told about it.
    var promptText: String {
        var lines = ["How the user does \"\(name)\" in \(appName) (Dottie watched them): \(summary)"]
        if !goal.isEmpty { lines.append("Goal: \(goal)") }
        if !method.isEmpty { lines.append("Their way: " + method.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: " ")) }
        if !interfaceNotes.isEmpty { lines.append("Where things are: " + interfaceNotes.joined(separator: "; ")) }
        if !worksFor.isEmpty { lines.append("Use the same way for: \(worksFor)") }
        return lines.joined(separator: "\n")
    }
}

@MainActor
final class DottieWatchAndLearn: ObservableObject {
    static let shared = DottieWatchAndLearn()

    @Published private(set) var isWatching = false
    @Published private(set) var howTos: [DottieWatchedHowTo] = []
    /// "Watching… 12 s" while it runs, "Learned …" after.
    @Published private(set) var statusLine = ""

    /// Shows progress and results in the notch (set by CompanionManager).
    var onStatus: ((_ title: String, _ text: String) -> Void)?

    private var frames: [Data] = []
    private var frameTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var startedAt: Date?
    private var userNote = ""
    /// False when a smart replay was already being recorded, so stopping
    /// here doesn't end the user's recording.
    private var startedActionRecorder = false

    static let defaultSeconds = 30
    static let maximumSeconds = 180
    private static let frameIntervalSeconds: Double = 2
    private static let maximumFramesSent = 10

    private let watcherBot = DottieClaudeBot(
        helperName: "Dottie Watcher",
        title: "Learns how the user does things by watching",
        instructions: DottieWatchAndLearn.watcherInstructions,
        folderName: "Watched",
        agentID: UUID(uuidString: "4F8A2C6E-1B3D-4E5F-A7B9-C0D1E2F3A4B5") ?? UUID()
    )

    private static var storeURL: URL {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folderURL = applicationSupportURL.appendingPathComponent("Dottie/Watched", isDirectory: true)
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        return folderURL.appendingPathComponent("howtos.json")
    }

    private init() {
        load()
    }

    // MARK: - Watching

    /// Starts watching for `seconds`, then learns. Returns a line to say.
    func start(seconds requestedSeconds: Int?, note: String?) -> String {
        guard !isWatching else { return "already watching. say \"stop watching\" when done." }
        guard CGPreflightScreenCaptureAccess() else { return "Dottie needs Screen Recording permission to watch." }
        let seconds = min(max(requestedSeconds ?? Self.defaultSeconds, 5), Self.maximumSeconds)
        // The actions recorder is shared with smart replays; while one is
        // being recorded, only frames are kept.
        startedActionRecorder = DottieSmartReplayRecorder.shared.start(kind: .smart)
        isWatching = true
        frames = []
        startedAt = Date()
        userNote = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        statusLine = "Watching…"
        onStatus?("Watching you", "Do the job as you normally would. I'll stop in \(seconds) seconds, or say \"stop watching\".")
        frameTask = Task { [weak self] in
            var lastFingerprint: [UInt8]?
            while !Task.isCancelled {
                guard let self, self.isWatching else { return }
                if let screen = await DottieDisplayCapture.captureActiveDisplay(maximumDimension: 1280) {
                    // Frames that look the same as the last one add nothing.
                    let fingerprint = Self.fingerprint(of: screen.image)
                    if lastFingerprint.map({ !Self.isSameScreen($0, fingerprint) }) ?? true {
                        self.frames.append(screen.jpegData)
                        if self.frames.count > 90 { self.frames.removeFirst() }
                    }
                    lastFingerprint = fingerprint
                }
                if let startedAt = self.startedAt {
                    self.statusLine = "Watching… \(Int(Date().timeIntervalSince(startedAt))) s"
                }
                try? await Task.sleep(nanoseconds: UInt64(Self.frameIntervalSeconds * 1_000_000_000))
            }
        }
        stopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            guard !Task.isCancelled, let self, self.isWatching else { return }
            _ = await self.stopAndLearn()
        }
        return "watching for \(seconds) seconds. tell the user to go ahead and do it as they normally would; you'll say what you learned after."
    }

    /// Stops watching and works out what the user did. Returns a line to say.
    func stopAndLearn() async -> String {
        guard isWatching else { return "not watching right now." }
        isWatching = false
        frameTask?.cancel()
        stopTask?.cancel()
        let actionLines = startedActionRecorder ? (DottieSmartReplayRecorder.shared.stop() ?? []) : []
        startedActionRecorder = false
        let watchedFrames = frames
        frames = []
        guard !watchedFrames.isEmpty else {
            statusLine = ""
            return "nothing was seen (no screen frames). say so."
        }
        statusLine = "Working out what you did…"
        onStatus?("Got it", "Working out what you were doing…")
        let frontmostAppName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        guard let howTo = await understand(frames: watchedFrames, actionLines: actionLines, appNameHint: frontmostAppName) else {
            statusLine = ""
            return "couldn't work out what the user was doing (the AI models didn't answer). say so and offer to watch again."
        }
        var savedHowTo = howTo
        savedHowTo.skillName = saveAsSkill(howTo)
        howTos.removeAll { $0.name.lowercased() == savedHowTo.name.lowercased() && $0.appName == savedHowTo.appName }
        howTos.append(savedHowTo)
        save()
        statusLine = "Learned \(savedHowTo.name)"
        onStatus?("Learned: \(savedHowTo.name)", savedHowTo.summary)
        return "learned it. what you understood: \(savedHowTo.summary) tell the user in one or two short lines what you understood, and that you can now do it, or similar jobs, by yourself."
    }

    // MARK: - Understanding

    private func understand(frames watchedFrames: [Data], actionLines: [String], appNameHint: String) async -> DottieWatchedHowTo? {
        let pickedFrames = Self.evenlySpaced(watchedFrames, count: Self.maximumFramesSent)
        let actionsText = actionLines.isEmpty ? "(no clicks or typing were caught)" : actionLines.joined(separator: "\n")
        let noteText = userNote.isEmpty ? "" : "The user said this is: \(userNote)\n"

        var reply: [String: Any]?
        if watcherBot.isWorthTrying {
            var frameLines: [String] = []
            for (index, frameData) in pickedFrames.enumerated() {
                let frameURL = watcherBot.workspaceURL.appendingPathComponent("watch-frame-\(index + 1).jpg")
                if (try? frameData.write(to: frameURL, options: .atomic)) != nil {
                    frameLines.append("- `\(frameURL.path)`")
                }
            }
            let message = """
            Open these frames of the user's screen, in order, taken every few seconds while they worked:
            \(frameLines.joined(separator: "\n"))

            What they did, as caught by the Mac (lines in [brackets] say which app and site):
            \(actionsText)

            \(noteText)Reply with only the JSON object.
            """
            if let replyText = await watcherBot.send(message, newConversation: true, timeoutSeconds: 90) {
                reply = DottieClaudeBot.jsonObject(in: replyText)
            }
        }
        if reply == nil {
            reply = await askGemini(frames: pickedFrames, actionsText: actionsText, noteText: noteText)
        }
        guard let reply, let name = (reply["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return DottieWatchedHowTo(
            learnedAt: Date(),
            name: String(name.prefix(60)),
            appName: (reply["app"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? appNameHint,
            summary: reply["summary"] as? String ?? "",
            goal: reply["goal"] as? String ?? "",
            method: reply["method"] as? [String] ?? [],
            interfaceNotes: reply["interface_notes"] as? [String] ?? [],
            worksFor: reply["works_for"] as? String ?? ""
        )
    }

    private func askGemini(frames pickedFrames: [Data], actionsText: String, noteText: String) async -> [String: Any]? {
        var parts: [[String: Any]] = pickedFrames.map { frameData in
            ["inlineData": ["mimeType": "image/jpeg", "data": frameData.base64EncodedString()]]
        }
        parts.append(["text": "Those are frames of the user's screen, in order. What they did, as caught by the Mac:\n\(actionsText)\n\(noteText)Reply with only the JSON object."])
        var request = URLRequest(url: ClickyWorkerConfiguration.url(forRoute: "/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        ClickyWorkerConfiguration.applyAuthenticationHeaders(to: &request)
        let model = DottieModelPicker.normalModelName
        let requestBody: [String: Any] = [
            "model": model,
            "systemInstruction": ["parts": [["text": Self.watcherInstructions]]],
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": ["responseMimeType": "application/json"]
        ]
        guard let requestData = try? JSONSerialization.data(withJSONObject: requestBody) else { return nil }
        request.httpBody = requestData
        guard let (responseData, response) = try? await DottieModelPicker.shared.data(for: request, model: model, totalSeconds: 75),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let replyText = GeminiServerSentEvents.parts(from: responseData)
            .filter { ($0["thought"] as? Bool) != true }
            .compactMap { $0["text"] as? String }
            .joined()
        return DottieClaudeBot.jsonObject(in: replyText)
    }

    private static let watcherInstructions = """
    You watch a user work on their Mac (a few screen frames in order, plus the clicks, typing and app switches the Mac caught) and write down what they were doing and how, so an assistant can do the same kind of job on its own later, including similar jobs that aren't exactly the same (another sheet, another table, other names).

    Describe the understanding, not raw clicks: the goal, their method as general steps by meaning ("add a SUM row under the totals column", "filter the table by status = open"), where things are in this app (menus, panels, buttons by their names), and what would change in a similar job. Keep the user's own names and values only where they define the method. Never write down passwords or other secrets you see.

    Reply with only a JSON object:
    {"name": "2-5 words naming the job", "app": "the app or website", "summary": "one or two plain sentences of what they did", "goal": "what it achieves", "method": ["general step", "..."], "interface_notes": ["where something is", "..."], "works_for": "the kinds of similar tasks this way fits"}
    """

    // MARK: - Using what was learned

    /// The how-tos that fit a job, for its instructions. "" when none.
    func howToText(forTask taskText: String, appName: String?) -> String {
        let matchingHowTos = howTos.filter { howTo in
            DottieTaskMatching.howToFits(taskText: taskText, frontmostAppName: appName,
                                         howToName: howTo.name, howToGoal: howTo.goal, howToAppName: howTo.appName)
        }
        if !matchingHowTos.isEmpty {
            DottieLog.notice("🎓 Using \(public: matchingHowTos.count) learned how-to(s): \(public: matchingHowTos.map(\.name).joined(separator: ", "))")
        }
        return matchingHowTos.suffix(3).map(\.promptText).joined(separator: "\n\n")
    }

    func forget(named spokenName: String) -> Bool {
        let wantedName = spokenName.lowercased()
        guard let howTo = howTos.first(where: { $0.name.lowercased().contains(wantedName) || wantedName.contains($0.name.lowercased()) }) else { return false }
        howTos.removeAll { $0.id == howTo.id }
        save()
        return true
    }

    /// Saves the how-to as a library skill, on for every Dot. Returns its
    /// name, or nil when the library isn't reachable.
    private func saveAsSkill(_ howTo: DottieWatchedHowTo) -> String? {
        guard let clickyRoster = DottieSelfKnowledge.companionManager?.clickyRoster else { return nil }
        let displayName = "Watched: \(howTo.name)"
        let skillName = ClickySkillLibrary.skillName(from: displayName)
        // Watching the same job again replaces the old notes.
        let existingFolderURL = clickyRoster.skillLibrary.libraryURL.appendingPathComponent(skillName, isDirectory: true)
        try? FileManager.default.removeItem(at: existingFolderURL)
        let instructions = """
        Learned by watching the user. Use this way for this job and similar ones (\(howTo.worksFor.isEmpty ? "the same kind of task" : howTo.worksFor)), adapting names and values to the new task.

        \(howTo.promptText)
        """
        guard let skill = try? clickyRoster.skillLibrary.createSkill(
            displayName: displayName,
            description: "How the user does \(howTo.name) in \(howTo.appName); use for that and similar tasks.",
            instructions: instructions
        ) else { return nil }
        clickyRoster.enableSkillForAllAgents(skill.name)
        return skill.name
    }

    // MARK: - Helpers

    private static func evenlySpaced(_ allFrames: [Data], count: Int) -> [Data] {
        guard allFrames.count > count, count > 1 else { return allFrames }
        return (0..<count).map { index in
            allFrames[index * (allFrames.count - 1) / (count - 1)]
        }
    }

    private static func fingerprint(of image: CGImage) -> [UInt8] {
        let width = 48, height = 30
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return pixels }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    private static func isSameScreen(_ first: [UInt8], _ second: [UInt8]) -> Bool {
        guard first.count == second.count else { return false }
        let changedPixelCount = zip(first, second).filter { abs(Int($0) - Int($1)) > 12 }.count
        return changedPixelCount < first.count / 200
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let savedHowTos = DottieFileLoader.load([DottieWatchedHowTo].self, from: Self.storeURL, decoder: decoder) else { return }
        howTos = savedHowTos
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let storeData = try? encoder.encode(howTos) else { return }
        DottieFileSaver.save(storeData, to: Self.storeURL)
    }
}

// MARK: - The voice tool

@MainActor
enum DottieWatchAndLearnTools: DottieToolModule {
    static var tools: [DottieTool] {
        [
            DottieTool(
                name: "watch_and_learn",
                description: "Watch the user do a job on their Mac for a while (default 30 seconds) and understand it in words, so Dottie can later do that job, or similar ones, by herself: 'watch me do this', 'learn how I do my spreadsheet', 'watch me for a minute'. start begins watching (seconds, and note: what they said the job is); stop ends early and learns; list says what was learned; forget removes one by name. After learning, similar screen jobs and helpers use it on their own.",
                parameters: [
                    "type": "OBJECT",
                    "properties": [
                        "action": ["type": "STRING", "enum": ["start", "stop", "list", "forget"]],
                        "seconds": ["type": "NUMBER", "description": "For start: how long to watch, if they said (5 to 180)."],
                        "note": ["type": "STRING", "description": "For start: what they said the job is. For forget: its name."]
                    ],
                    "required": ["action"]
                ],
                audiences: [.voice]
            ) { arguments in
                let watcher = DottieWatchAndLearn.shared
                switch arguments.dottieString("action") ?? "list" {
                case "start":
                    let seconds = arguments.dottieNumber("seconds").map { Int($0) }
                    return watcher.start(seconds: seconds, note: arguments.dottieString("note"))
                case "stop":
                    return await watcher.stopAndLearn()
                case "forget":
                    let name = arguments.dottieString("note") ?? ""
                    return watcher.forget(named: name) ? "forgot it." : "no learned job called that."
                default:
                    guard !watcher.howTos.isEmpty else { return "nothing learned by watching yet." }
                    return "learned by watching: " + watcher.howTos.map { "\($0.name) (\($0.appName))" }.joined(separator: ", ")
                }
            }
        ]
    }

    /// Voice Dottie hears what she learned by watching, and that doing it
    /// again is a screen job. Before, only screen jobs and helpers knew, so
    /// "do the same for the other one" went to a helper with no screen,
    /// which answered that it had no access.
    static var voicePromptSection: String {
        var section = "when the user wants you to watch them do something and learn it, use watch_and_learn."
        let learnedNames = DottieWatchAndLearn.shared.howTos.suffix(12).map { "\"\($0.name)\" (\($0.appName))" }
        if !learnedNames.isEmpty {
            section += " you learned these by watching the user: \(learnedNames.joined(separator: ", ")). when they ask for one of them or something like it (\"do it again\", \"do the same for march\", \"move the other one too\"), call do_task_on_screen with their words: you do it on their screen with the how-to you learned. never hand it to a helper or ask_brain, and never say you don't have access."
        } else {
            section += " right after you learn something, \"do it again\" or \"do the same for…\" is a do_task_on_screen job, never a helper's."
        }
        return section
    }
}
