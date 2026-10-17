//
//  DottieTVTaskRunner.swift
//  leanring-buddy
//
//  Multi-step jobs on a TV ("put on the next episode of Bluey", "what's on
//  the TV?", "turn on subtitles"), like screen jobs on the Mac but with a
//  remote: look at the TV's screen (ADB screenshot or a capture card), ask
//  Gemini for the next buttons, press them, look again. A TV has no mouse,
//  so every move is a remote button, typing or opening an app or link.
//

import AppKit
import Foundation
import ImageIO

@MainActor
final class DottieTVTaskRunner {
    /// What the runner can do with one TV; DottieSmartHome builds it.
    struct Controls {
        let tvName: String
        /// The TV's screen as PNG or JPEG, or nil when it can't be seen.
        let captureScreen: () async -> Data?
        let press: (String) async -> Bool
        let type: (String) async -> Bool
        let openApp: (String) async -> String
        let openURL: ((String) async -> Bool)?
    }

    enum Outcome {
        case finished(String)
        case failed(String)
        case stopped
    }

    private(set) var isRunning = false
    private var runTask: Task<Void, Never>?
    var onProgress: ((String) -> Void)?

    private static let model = "gemini-3.5-flash-lite"
    private static let maximumSteps = 30

    func start(task: String, controls: Controls, completion: @escaping (Outcome) -> Void) {
        runTask?.cancel()
        isRunning = true
        runTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.run(task: task, controls: controls)
            self.isRunning = false
            completion(outcome)
        }
    }

    @discardableResult
    func stop() -> Bool {
        guard isRunning else { return false }
        runTask?.cancel()
        isRunning = false
        return true
    }

    private func run(task: String, controls: Controls) async -> Outcome {
        var contents: [[String: Any]] = []
        var pendingResponses: [[String: Any]] = []
        var failures = 0
        // Tips from earlier jobs on this TV, scored by how this one ends.
        let lessonAppName = "TV \(controls.tvName)"
        let lessonSelection = DottieScreenLessons.shared.select(forTask: task, frontmostAppName: lessonAppName)

        for stepNumber in 1...Self.maximumSteps {
            if Task.isCancelled { return .stopped }
            guard let screenData = await controls.captureScreen(),
                  let screenJPEG = Self.smallJPEG(from: screenData) else {
                return .failed("couldn't see the TV's screen. it may be off, or not connected.")
            }
            var userParts = pendingResponses
            userParts.append(["inlineData": ["mimeType": "image/jpeg", "data": screenJPEG.base64EncodedString()]])
            userParts.append(["text": contents.isEmpty
                ? "Task from the user, on their TV \"\(controls.tvName)\": \(task)\n\(lessonSelection.promptText)This is the TV screen now. Take the first step."
                : "This is the TV screen now. Which steps are done? Take the next one, or finish."])
            contents.append(["role": "user", "parts": userParts])
            pendingResponses = []
            Self.keepNewestScreens(in: &contents)

            let modelParts: [[String: Any]]
            do {
                modelParts = try await requestNextStep(contents: contents)
                failures = 0
            } catch {
                failures += 1
                if failures >= 3 { return .failed("Gemini stopped answering (\(error.localizedDescription)).") }
                contents.removeLast()
                pendingResponses = (userParts.filter { $0["functionResponse"] != nil })
                try? await Task.sleep(nanoseconds: UInt64(failures) * 3_000_000_000)
                continue
            }
            if Task.isCancelled { return .stopped }
            contents.append(["role": "model", "parts": modelParts])

            let functionCalls = modelParts.compactMap { $0["functionCall"] as? [String: Any] }
            guard !functionCalls.isEmpty else { return .failed("Gemini didn't give a next step.") }
            for functionCall in functionCalls {
                let name = functionCall["name"] as? String ?? ""
                let arguments = functionCall["args"] as? [String: Any] ?? [:]
                if name == "finish" {
                    let didSucceed = (arguments["succeeded"] as? Bool) ?? true
                    DottieScreenLessons.shared.recordOutcome(lessonIDs: lessonSelection.lessonIDs, succeeded: didSucceed)
                    if let lesson = (arguments["lesson"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !lesson.isEmpty {
                        DottieScreenLessons.shared.add(lesson, task: task, appName: lessonAppName, cameFromSuccess: didSucceed)
                    }
                    return .finished((arguments["summary"] as? String) ?? "done.")
                }
                let result = await perform(name: name, arguments: arguments, controls: controls, stepNumber: stepNumber)
                var functionResponse: [String: Any] = ["name": name, "response": ["result": result]]
                if let callID = functionCall["id"] as? String { functionResponse["id"] = callID }
                pendingResponses.append(["functionResponse": functionResponse])
            }
            // Give the TV a moment to react before looking again.
            try? await Task.sleep(nanoseconds: 900_000_000)
        }
        DottieScreenLessons.shared.recordOutcome(lessonIDs: lessonSelection.lessonIDs, succeeded: false)
        return .failed("it took more than \(Self.maximumSteps) steps, so I stopped.")
    }

    private func perform(name: String, arguments: [String: Any], controls: Controls, stepNumber: Int) async -> String {
        switch name {
        case "press":
            let keys = ((arguments["keys"] as? [Any]) ?? []).compactMap { ($0 as? String)?.lowercased() }.prefix(10)
            guard !keys.isEmpty else { return "error: no buttons" }
            onProgress?("pressing \(keys.joined(separator: ", "))")
            for key in keys {
                if Task.isCancelled { return "stopped" }
                guard await controls.press(key) else { return "the \(key) button didn't work (or isn't a button)." }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            return "pressed \(keys.joined(separator: ", "))"
        case "type_text":
            let text = (arguments["text"] as? String) ?? ""
            onProgress?("typing \(text)")
            return await controls.type(text) ? "typed it" : "typing didn't work"
        case "open_app":
            let appName = (arguments["name"] as? String) ?? ""
            onProgress?("opening \(appName)")
            let result = await controls.openApp(appName)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return result
        case "open_link":
            guard let openURL = controls.openURL, let url = arguments["url"] as? String else { return "this TV can't open links." }
            onProgress?("opening a link")
            let didOpen = await openURL(url)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return didOpen ? "opened it" : "couldn't open it"
        case "wait":
            let seconds = min(max((arguments["seconds"] as? NSNumber)?.doubleValue ?? 2, 0.5), 20)
            onProgress?("waiting")
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return "waited"
        default:
            return "unknown action"
        }
    }

    // MARK: - Gemini

    private func requestNextStep(contents: [[String: Any]]) async throws -> [[String: Any]] {
        var request = URLRequest(url: ClickyWorkerConfiguration.url(forRoute: "/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 40
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        ClickyWorkerConfiguration.applyAuthenticationHeaders(to: &request)
        let body: [String: Any] = [
            "model": Self.model,
            "systemInstruction": ["parts": [["text": Self.systemInstruction]]],
            "contents": contents,
            "tools": [["functionDeclarations": Self.functionDeclarations]],
            "toolConfig": ["functionCallingConfig": ["mode": "ANY"]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard statusCode == 200 else {
            throw NSError(domain: "DottieTVTaskRunner", code: statusCode, userInfo: [
                NSLocalizedDescriptionKey: "error \(statusCode)"
            ])
        }
        let parts = GeminiServerSentEvents.parts(from: data)
        guard !parts.isEmpty else {
            throw NSError(domain: "DottieTVTaskRunner", code: -2, userInfo: [NSLocalizedDescriptionKey: "empty answer"])
        }
        return parts
    }

    private static let systemInstruction = """
    You use the user's TV for them with its remote, one quick step at a time. Each turn you get a picture of the TV screen; call the next action.
    - Move with the arrow buttons and press ok to choose; the highlighted item has a border, a glow or is bigger. Count how many presses it takes to get from the highlighted item to the one you want and press them all in one go.
    - To open an app, use open_app with its name instead of hunting for it on the home screen. To search inside an app, find its search box, press ok, then type_text.
    - back goes back, home goes to the home screen. If something pops up (a profile picker, "are you still watching", an ad), deal with it and carry on.
    - Loading screens: use wait.
    - Before anything that costs money, deletes something or can't be undone, finish and say what you'd do, so the user can decide.
    - When the job is done, or the user only asked what's on, call finish with a short, friendly answer about what's on the screen now.
    """

    private static var functionDeclarations: [[String: Any]] {
        [
            [
                "name": "press",
                "description": "Press remote buttons in order.",
                "parameters": ["type": "object", "properties": [
                    "keys": ["type": "array", "items": ["type": "string", "enum": DottieTV.remoteKeyNames]]
                ], "required": ["keys"]]
            ],
            [
                "name": "type_text",
                "description": "Type into the text box that's open on the TV.",
                "parameters": ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]]
            ],
            [
                "name": "open_app",
                "description": "Open an app on the TV by name, like YouTube, Netflix or Settings.",
                "parameters": ["type": "object", "properties": ["name": ["type": "string"]], "required": ["name"]]
            ],
            [
                "name": "open_link",
                "description": "Open a link on the TV, like a YouTube video URL (Android and Google TV only).",
                "parameters": ["type": "object", "properties": ["url": ["type": "string"]], "required": ["url"]]
            ],
            [
                "name": "wait",
                "description": "Wait for something to load.",
                "parameters": ["type": "object", "properties": ["seconds": ["type": "number"]], "required": ["seconds"]]
            ],
            [
                "name": "finish",
                "description": "The job is done (or can't be done). Say the result in one short sentence.",
                "parameters": ["type": "object", "properties": [
                    "summary": ["type": "string"],
                    "succeeded": ["type": "boolean", "description": "true if the job got done."],
                    "lesson": ["type": "string", "description": "One short tip for this kind of job on this TV next time (the path that worked, or what to avoid). Empty if it was easy."]
                ], "required": ["summary"]]
            ]
        ]
    }

    // MARK: - Pictures

    private static func smallJPEG(from imageData: Data, maximumDimension: CGFloat = 1280) -> Data? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumDimension
              ] as CFDictionary) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.75])
    }

    private static func keepNewestScreens(in contents: inout [[String: Any]]) {
        var seen = 0
        for contentIndex in contents.indices.reversed() {
            guard var parts = contents[contentIndex]["parts"] as? [[String: Any]] else { continue }
            var changed = false
            for partIndex in parts.indices.reversed() where parts[partIndex]["inlineData"] != nil {
                seen += 1
                if seen > 2 {
                    parts[partIndex] = ["text": "(older TV screen removed)"]
                    changed = true
                }
            }
            if changed { contents[contentIndex]["parts"] = parts }
        }
    }
}
