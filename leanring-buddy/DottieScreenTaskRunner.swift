//
//  DottieScreenTaskRunner.swift
//  leanring-buddy
//
//  Multi-step jobs on the screen, done in one go: "open Opera, search
//  kaggle, go to my competitions, open the RSNA knee one and tell me my
//  rank". Voice Dottie hands the whole request here (do_task_on_screen) and
//  this runs the classic look-act loop until it's done:
//
//    1. Screenshot the display the user is working on (without Dottie's own
//       windows) and send it to Gemini Flash with the task, the steps so far
//       and a small set of actions as function declarations.
//    2. Gemini answers with the next action: open an app or page, click a
//       box on the screenshot, type, press keys, scroll, wait, or finish
//       with what to tell the user.
//    3. Do it (Dottie's cursor flies to every click first), wait for the
//       screen to settle, and go again.
//
//  Gemini Flash returns exact boxes for what it sees (verified 2026-10-16 on
//  the free tier: box_2d within a few pixels on a 1440px screenshot), so
//  clicks land on the thing itself. The loop stops on finish, after
//  maximumSteps, or when the user stops it (Escape, the notch, or by voice).
//

import AppKit
import ApplicationServices
import Foundation
import ScreenCaptureKit

@MainActor
final class DottieScreenTaskRunner {
    enum Outcome {
        /// Done; the answer is what to tell the user.
        case finished(answer: String)
        /// The user stopped it.
        case stopped
        /// Gave up: Gemini unreachable, too many steps, no screen access.
        case failed(reason: String)
    }

    static let maximumSteps = 30
    /// Games take many small moves.
    static let maximumGameSteps = 150
    /// Fast and on the free tier; the Worker falls back to other Flash
    /// models when it's busy.
    private static let taskModel = "gemini-3.6-flash"
    /// Older screenshots are dropped from the conversation to keep requests
    /// small; the action log still says what happened.
    private static let keptScreenshotCount = 2
    private static let maximumScreenshotDimension = 1440
    /// Games favor speed: a smaller frame and the quickest model (a box
    /// lookup takes about a second on it, Oct 2026).
    private static let gameScreenshotDimension = 1024
    private static let gameModel = "gemini-3.5-flash-lite"

    /// A picture the user saved in Home → Conversation that the job needs
    /// ("grab the golden sword").
    struct ReferenceImage {
        let name: String
        let description: String
        let jpegData: Data
    }

    /// Progress for the notch: step number and what's happening.
    var onProgress: (@MainActor (_ stepNumber: Int, _ description: String) -> Void)?
    /// Saves a picture of something on screen to the picture library
    /// (save_picture): image data, name, description. Returns the result.
    var onSavePicture: (@MainActor (_ imageData: Data, _ name: String, _ description: String) -> String)?
    /// Called before each click with the global point and its display, so
    /// Dottie's cursor can fly there first.
    var onWillClick: (@MainActor (_ point: CGPoint, _ displayFrame: CGRect) async -> Void)?

    private(set) var currentTaskText: String?
    private var runTask: Task<Void, Never>?
    private var isGameMode = false
    /// How far the character moves per second of a held key, in screen
    /// points, learned from each walk_to (games differ a lot).
    private var walkSpeedPointsPerSecond: CGFloat = 220
    /// Where the last top-down walk started and how far it meant to go,
    /// to learn the real speed from where the character ended up.
    private var lastWalk: (start: CGPoint, plannedDistance: CGFloat, plannedDirection: CGVector)?
    /// Free-tier models allow about 15 requests a minute, so a game's
    /// quick loop is spaced out a little to avoid hitting the limit.
    private static let minimumGameRequestSpacingSeconds: TimeInterval = 2.5
    private var lastRequestStartedAt: Date?
    /// Sent at the start of every request, so the pictures are never
    /// dropped with old screenshots.
    private var referenceImageParts: [[String: Any]] = []
    /// Game jobs: where things are, built up while playing (DottieGameMap).
    private var gameMap: DottieGameMap?
    /// Camera directions of the last look_around's views, for landmarks
    /// noted in them.
    private var lookAroundHeadings: [Double] = []
    /// Extra pictures for the next turn: zoomed crops, look-around views.
    private var pendingExtraImageParts: [[String: Any]] = []

    var isRunning: Bool { runTask != nil }

    func start(
        task taskText: String,
        isGameMode: Bool = false,
        referenceImages: [ReferenceImage] = [],
        completion: @escaping @MainActor (Outcome) -> Void
    ) {
        stop()
        currentTaskText = taskText
        self.isGameMode = isGameMode
        walkSpeedPointsPerSecond = 220
        lastWalk = nil
        lastRequestStartedAt = nil
        pendingExtraImageParts = []
        lookAroundHeadings = []
        gameMap = isGameMode ? DottieGameMap(gameName: Self.currentGameName()) : nil
        referenceImageParts = referenceImages.enumerated().flatMap { index, referenceImage -> [[String: Any]] in
            [
                ["text": "Reference picture \(index + 1), \"\(referenceImage.name)\", which the user shared earlier"
                    + (referenceImage.description.isEmpty ? "" : " (\(referenceImage.description))")
                    + ". When the task mentions it, it means the thing in this picture: find it on the screen by its look."],
                ["inlineData": ["mimeType": "image/jpeg", "data": referenceImage.jpegData.base64EncodedString()]]
            ]
        }
        runTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.run(taskText: taskText)
            guard !Task.isCancelled else { return }
            self.runTask = nil
            self.currentTaskText = nil
            completion(outcome)
        }
    }

    /// Stops after the current action. Returns true if a task was running.
    @discardableResult
    func stop() -> Bool {
        guard let runTask else { return false }
        runTask.cancel()
        self.runTask = nil
        currentTaskText = nil
        return true
    }

    // MARK: - The loop

    private func run(taskText: String) async -> Outcome {
        guard DottieScreenActionPerformer.canPostEvents else {
            return .failed(reason: "I need Accessibility permission to click and type for you: System Settings → Privacy & Security → Accessibility.")
        }

        var contents: [[String: Any]] = []
        var pendingFunctionResponseParts: [[String: Any]] = []
        var consecutiveRequestFailures = 0
        // Spotting a stuck loop: what the screen looked like before the last
        // actions, and the actions themselves.
        var previousScreenFingerprint: [UInt8]?
        var didActSinceLastLook = false
        var recentActionSignatures: [String] = []
        var actionLog: [String] = []
        let lessonsText = DottieScreenLessons.shared.promptText(forTask: taskText, frontmostAppName: NSWorkspace.shared.frontmostApplication?.localizedName)

        let stepLimit = isGameMode ? Self.maximumGameSteps : Self.maximumSteps
        for stepNumber in 1...stepLimit {
            if Task.isCancelled { return .stopped }

            let screenshotDimension = isGameMode ? Self.gameScreenshotDimension : Self.maximumScreenshotDimension
            guard let screen = await DottieDisplayCapture.captureActiveDisplay(maximumDimension: screenshotDimension) else {
                return .failed(reason: "I couldn't see the screen. Dottie needs Screen Recording permission.")
            }
            var screenNote = "Step \(stepNumber). " + Self.describeFrontmostWindow()
            let screenFingerprint = Self.fingerprint(of: screen.image)
            if !isGameMode, didActSinceLastLook,
               let previousScreenFingerprint, Self.isSameScreen(previousScreenFingerprint, screenFingerprint) {
                screenNote += "\nThe screen looks exactly the same as before your last action, so it probably didn't work (or it was already done). Don't repeat it: look at what's really on screen and try a different way, like pressing return, clicking a different spot or result, closing a popup, scrolling, or waiting."
            }
            if let repeatedAction = Self.repeatedAction(in: recentActionSignatures) {
                screenNote += "\nYou've done \(repeatedAction) several times and it isn't getting you further. Stop doing it. Check which steps of the task are already done on this screen and move to the next one, or try a completely different way."
            }
            previousScreenFingerprint = screenFingerprint
            didActSinceLastLook = false
            if let mapSummary = gameMap?.summary(currentStep: stepNumber), !mapSummary.isEmpty {
                screenNote += "\n" + mapSummary
            }
            // Every function call needs its response in the next user turn,
            // so a failed request puts these back for the retry.
            let functionResponsesForThisTurn = pendingFunctionResponseParts
            var userParts = functionResponsesForThisTurn
            userParts.append(["inlineData": ["mimeType": "image/jpeg", "data": screen.jpegData.base64EncodedString()]])
            userParts.append(contentsOf: pendingExtraImageParts)
            pendingExtraImageParts = []
            userParts.append(["text": contents.isEmpty
                ? "Task from the user: \(taskText)\n\(lessonsText)\n\(screenNote)\nThis is the screen now. Take the first step."
                : "\(screenNote)\nThis is the screen now. First check it against the task: which steps are already done? Then take the first step that isn't done yet."])
            contents.append(["role": "user", "parts": userParts])
            pendingFunctionResponseParts = []
            Self.dropOldScreenshots(from: &contents)

            let modelParts: [[String: Any]]
            do {
                modelParts = try await requestNextActions(contents: contents)
                consecutiveRequestFailures = 0
            } catch {
                if Task.isCancelled { return .stopped }
                consecutiveRequestFailures += 1
                print("⚠️ Screen task step \(stepNumber) failed: \(error.localizedDescription)")
                // A game waits out a per-minute limit rather than giving up.
                let isRateLimited = (error as NSError).code == 429
                if consecutiveRequestFailures >= (isGameMode && isRateLimited ? 6 : 3) {
                    let statusCode = (error as NSError).code
                    let wasBusy = [429, 500, 503, 504].contains(statusCode) || (error as? URLError)?.code == .timedOut
                    return .failed(reason: wasBusy
                        ? "Gemini's too busy to keep going right now."
                        : "Gemini stopped giving me steps (\(statusCode == -2 ? "empty answer" : "error \(statusCode)")), so I stopped.")
                }
                // Try the same step again with the same conversation, a
                // little later each time so a per-minute limit can reset.
                contents.removeLast()
                pendingFunctionResponseParts = functionResponsesForThisTurn
                let backoffSeconds = UInt64(consecutiveRequestFailures) * (isRateLimited ? 5 : 2)
                try? await Task.sleep(nanoseconds: backoffSeconds * 1_000_000_000)
                continue
            }
            if Task.isCancelled { return .stopped }

            contents.append(["role": "model", "parts": modelParts])
            let functionCalls = modelParts.compactMap { $0["functionCall"] as? [String: Any] }

            guard !functionCalls.isEmpty else {
                // Plain text instead of an action: treat it as the answer.
                let answerText = modelParts
                    .filter { ($0["thought"] as? Bool) != true }
                    .compactMap { $0["text"] as? String }
                    .joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return .finished(answer: answerText.isEmpty ? "All done." : answerText)
            }

            for functionCall in functionCalls {
                if Task.isCancelled { return .stopped }
                let functionName = functionCall["name"] as? String ?? ""
                let arguments = functionCall["args"] as? [String: Any] ?? [:]

                if functionName == "finish" {
                    let answer = (arguments["answer"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if let lesson = (arguments["lesson"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !lesson.isEmpty {
                        DottieScreenLessons.shared.add(lesson, task: taskText, appName: NSWorkspace.shared.frontmostApplication?.localizedName)
                    }
                    return .finished(answer: answer.isEmpty ? "All done." : answer)
                }

                recentActionSignatures.append(Self.signature(functionName: functionName, arguments: arguments))
                if recentActionSignatures.count > 6 { recentActionSignatures.removeFirst() }
                actionLog.append(Self.signature(functionName: functionName, arguments: arguments))
                let result = await perform(functionName: functionName, arguments: arguments, screen: screen, stepNumber: stepNumber)
                var functionResponse: [String: Any] = ["name": functionName, "response": ["result": result]]
                if let functionCallID = functionCall["id"] as? String {
                    functionResponse["id"] = functionCallID
                }
                pendingFunctionResponseParts.append(["functionResponse": functionResponse])
                didActSinceLastLook = true
            }

            // Let pages load and animations finish before the next look.
            // Games keep moving, so they get a quick look straight away.
            try? await Task.sleep(nanoseconds: isGameMode ? 200_000_000 : 900_000_000)
        }

        if !isGameMode {
            // Next time, the job starts knowing this path didn't work.
            DottieScreenLessons.shared.add(
                "This didn't finish in \(stepLimit) steps. Ended up repeating: \(actionLog.suffix(4).joined(separator: "; ")). Try a different route next time.",
                task: taskText,
                appName: NSWorkspace.shared.frontmostApplication?.localizedName
            )
        }
        return .failed(reason: "That took more than \(stepLimit) steps, so I stopped.")
    }

    // MARK: - Spotting a stuck loop

    /// A tiny grayscale copy of the screen, to tell whether an action
    /// changed anything.
    private static func fingerprint(of image: CGImage) -> [UInt8] {
        let width = 64, height = 40
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }

    /// Nearly no pixel moved (a blinking caret or clock doesn't count).
    private static func isSameScreen(_ first: [UInt8], _ second: [UInt8]) -> Bool {
        guard first.count == second.count, !first.isEmpty else { return false }
        let changedPixels = zip(first, second).filter { abs(Int($0) - Int($1)) > 12 }.count
        return Double(changedPixels) / Double(first.count) < 0.003
    }

    private static func signature(functionName: String, arguments: [String: Any]) -> String {
        let label = (arguments["label"] as? String) ?? (arguments["text"] as? String) ?? (arguments["keys"] as? String)
            ?? (arguments["url"] as? String) ?? (arguments["name"] as? String) ?? (arguments["direction"] as? String) ?? ""
        return label.isEmpty ? functionName : "\(functionName) \"\(label.prefix(60))\""
    }

    /// An action done three times in the last four (scrolling and waiting
    /// repeat legitimately, so they need more).
    private static func repeatedAction(in signatures: [String]) -> String? {
        guard let lastSignature = signatures.last else { return nil }
        let isNaturallyRepeated = lastSignature.hasPrefix("scroll") || lastSignature.hasPrefix("wait")
        let repeatCount = signatures.suffix(isNaturallyRepeated ? 6 : 4).filter { $0 == lastSignature }.count
        return repeatCount >= (isNaturallyRepeated ? 5 : 3) ? lastSignature : nil
    }

    // MARK: - Actions

    private func perform(functionName: String, arguments: [String: Any], screen: DottieDisplayCapture.Screenshot, stepNumber: Int) async -> String {
        func text(_ key: String) -> String? {
            let value = (arguments[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        func flag(_ key: String) -> Bool { (arguments[key] as? Bool) ?? ((arguments[key] as? NSNumber)?.boolValue ?? false) }
        func boxCenter() -> CGPoint? {
            guard let box = arguments["box_2d"] as? [Any] else { return nil }
            let numbers = box.compactMap { ($0 as? NSNumber)?.doubleValue }
            guard numbers.count == 4 else { return nil }
            let (ymin, xmin, ymax, xmax) = (numbers[0], numbers[1], numbers[2], numbers[3])
            guard ymax >= ymin, xmax >= xmin else { return nil }
            return screen.globalPoint(normalizedX: (xmin + xmax) / 2, normalizedY: (ymin + ymax) / 2)
        }
        /// The box's middle, moved to the middle of the real control under
        /// it when there is one, so a box a few pixels off still hits.
        func clickPoint() -> CGPoint? {
            guard let box = arguments["box_2d"] as? [Any] else { return nil }
            let numbers = box.compactMap { ($0 as? NSNumber)?.doubleValue }
            guard numbers.count == 4, numbers[2] >= numbers[0], numbers[3] >= numbers[1] else { return nil }
            let topLeft = screen.globalPoint(normalizedX: numbers[1], normalizedY: numbers[0])
            let bottomRight = screen.globalPoint(normalizedX: numbers[3], normalizedY: numbers[2])
            let boxFrame = CGRect(x: topLeft.x, y: bottomRight.y, width: bottomRight.x - topLeft.x, height: topLeft.y - bottomRight.y)
            let snappedFrame = AccessibilitySnap.refinedFrame(boxFrame)
            return CGPoint(x: snappedFrame.midX, y: snappedFrame.midY)
        }

        switch functionName {
        case "open_app":
            guard let appName = text("name") else { return "error: no app name" }
            onProgress?(stepNumber, "opening \(appName)")
            let didOpen = await Self.openApplication(named: appName)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            return didOpen ? "opened \(appName); it's in front now" : "couldn't find an app called \(appName)"

        case "open_url":
            guard var address = text("url") else { return "error: no url" }
            if !address.contains("://") { address = "https://" + address }
            guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                return "error: not a web address"
            }
            onProgress?(stepNumber, "opening \(url.host ?? address)")
            let didOpen: Bool
            if let browserName = text("browser") {
                didOpen = await Self.open(url, inApplicationNamed: browserName)
            } else {
                didOpen = NSWorkspace.shared.open(url)
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            return didOpen ? "opened \(address)" : "couldn't open \(address)"

        case "click":
            guard let point = clickPoint() else { return "error: box_2d must be [ymin, xmin, ymax, xmax] from 0 to 1000" }
            let label = text("label") ?? "it"
            onProgress?(stepNumber, "clicking \(label)")
            // In a game, a pause before every click costs the moment.
            if !isGameMode {
                await onWillClick?(point, screen.displayFrame)
            }
            if Task.isCancelled { return "stopped" }
            DottieScreenActionPerformer.click(at: point, clickCount: flag("double_click") ? 2 : 1, isRightClick: flag("right_click"))
            return "clicked \(label)"

        case "type_text":
            guard let typedText = arguments["text"] as? String, !typedText.isEmpty else { return "error: no text" }
            if let point = clickPoint() {
                await onWillClick?(point, screen.displayFrame)
                if Task.isCancelled { return "stopped" }
                DottieScreenActionPerformer.click(at: point, clickCount: 1, isRightClick: false)
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
            if DottieScreenActionPerformer.isFocusedFieldSecure {
                return "refused: that's a password field. The user has to type passwords themselves; finish and tell them."
            }
            onProgress?(stepNumber, "typing \"\(typedText.prefix(40))\"")
            if flag("select_all_first") {
                DottieScreenActionPerformer.press(keyCombination: "cmd+a")
            }
            await DottieScreenActionPerformer.type(typedText)
            if flag("press_enter") {
                try? await Task.sleep(nanoseconds: 150_000_000)
                DottieScreenActionPerformer.press(keyCombination: "enter")
            }
            return flag("press_enter") ? "typed it and pressed return" : "typed it"

        case "press_keys":
            guard let keys = text("keys") else { return "error: no keys" }
            onProgress?(stepNumber, "pressing \(keys)")
            return DottieScreenActionPerformer.press(keyCombination: keys)
                ? "pressed \(keys)"
                : "unknown key \(keys); use names like cmd+l, enter, escape, tab, up, down"

        case "scroll":
            guard let direction = text("direction").flatMap({ DottieScreenAction.ScrollDirection(rawValue: $0.lowercased()) }) else {
                return "error: direction must be up, down, left or right"
            }
            onProgress?(stepNumber, "scrolling \(direction.rawValue)")
            let amount = Int((arguments["amount"] as? NSNumber)?.doubleValue ?? 5)
            // Scroll where the content is, not wherever the user's pointer is.
            let scrollPoint = boxCenter() ?? screen.globalPoint(normalizedX: 500, normalizedY: 550)
            DottieScreenActionPerformer.scroll(direction: direction, amount: amount, at: scrollPoint)
            return "scrolled \(direction.rawValue)"

        case "hold_keys":
            guard let keys = text("keys") else { return "error: no keys" }
            let seconds = (arguments["seconds"] as? NSNumber)?.doubleValue ?? 1
            onProgress?(stepNumber, "holding \(keys)")
            guard await DottieScreenActionPerformer.hold(keyCombination: keys, seconds: seconds) else {
                return "unknown key in \(keys); use names like w, a, s, d, space, shift, up, e"
            }
            gameMap?.noteMovement(keys: keys, seconds: min(max(seconds, 0.05), 5))
            return "held \(keys) for \(String(format: "%.1f", min(max(seconds, 0.05), 5)))s"

        case "walk_to":
            return await walk(arguments: arguments, screen: screen, stepNumber: stepNumber)

        case "move_mouse":
            let deltaX = CGFloat((arguments["dx"] as? NSNumber)?.doubleValue ?? 0)
            let deltaY = CGFloat((arguments["dy"] as? NSNumber)?.doubleValue ?? 0)
            let button = text("button")?.lowercased() ?? "none"
            onProgress?(stepNumber, "turning the camera")
            // dx and dy are 0-1000 across the screenshot, like boxes.
            let startPoint = boxCenter() ?? screen.globalPoint(normalizedX: 500, normalizedY: 500)
            let deltaXPoints = deltaX / 1000 * screen.displayFrame.width
            await DottieScreenActionPerformer.moveMouse(
                from: startPoint,
                deltaX: deltaXPoints,
                deltaY: -deltaY / 1000 * screen.displayFrame.height,
                button: button,
                seconds: (arguments["seconds"] as? NSNumber)?.doubleValue ?? 0.4
            )
            if let gameMap, button != "left", deltaXPoints != 0 {
                // Measure this game's camera speed on small turns, where
                // the before and after views still overlap.
                if abs(deltaXPoints) < screen.displayFrame.width * 0.3,
                   let afterImage = await DottieDisplayCapture.captureImage(displayFrame: screen.displayFrame, maximumDimension: 640) {
                    gameMap.calibrate(before: screen.image, after: afterImage, turnedMousePoints: deltaXPoints)
                }
                gameMap.noteCameraTurn(mousePoints: deltaXPoints)
            }
            return "moved the mouse \(Int(deltaX)), \(Int(deltaY)) with \(button == "none" ? "no button" : "the \(button) button") held"

        case "wait":
            let seconds = min(max((arguments["seconds"] as? NSNumber)?.doubleValue ?? 2, 0.5), 120)
            onProgress?(stepNumber, seconds > 10 ? "waiting \(Int(seconds)) seconds" : "waiting for it to load")
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return "waited \(Int(seconds.rounded())) seconds"

        case "zoom":
            guard let box = arguments["box_2d"] as? [Any] else { return "error: zoom needs box_2d" }
            let numbers = box.compactMap { ($0 as? NSNumber)?.doubleValue }
            guard numbers.count == 4, numbers[2] > numbers[0], numbers[3] > numbers[1],
                  let sharpImage = await DottieDisplayCapture.captureImage(displayFrame: screen.displayFrame, maximumDimension: 2880) else {
                return "error: box_2d must be [ymin, xmin, ymax, xmax]"
            }
            let imageWidth = Double(sharpImage.width), imageHeight = Double(sharpImage.height)
            let cropRect = CGRect(
                x: numbers[1] / 1000 * imageWidth, y: numbers[0] / 1000 * imageHeight,
                width: (numbers[3] - numbers[1]) / 1000 * imageWidth, height: (numbers[2] - numbers[0]) / 1000 * imageHeight
            ).integral
            guard let croppedImage = sharpImage.cropping(to: cropRect),
                  let croppedJPEG = NSBitmapImageRep(cgImage: croppedImage).representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
                return "couldn't zoom there."
            }
            onProgress?(stepNumber, "taking a closer look")
            pendingExtraImageParts.append(["text": "Zoomed-in view of box \(numbers.map { Int($0) }) on the screenshot before this one (sharper; boxes for actions still go on the full screenshot):"])
            pendingExtraImageParts.append(["inlineData": ["mimeType": "image/jpeg", "data": croppedJPEG.base64EncodedString()]])
            return "zoomed in; the close-up comes with the next screenshot."

        case "note_landmarks":
            guard let gameMap else { return "landmarks are for game mode." }
            let rawLandmarks = (arguments["landmarks"] as? [Any]) ?? []
            var notedNames: [String] = []
            for case let rawLandmark as [String: Any] in rawLandmarks {
                guard let name = (rawLandmark["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                      let screenX = (rawLandmark["screen_x"] as? NSNumber)?.doubleValue else { continue }
                let view = (rawLandmark["view"] as? NSNumber)?.intValue ?? 0
                let heading = view >= 1 && view <= lookAroundHeadings.count ? lookAroundHeadings[view - 1] : nil
                gameMap.noteLandmark(
                    name: name,
                    description: (rawLandmark["description"] as? String) ?? "",
                    screenX: screenX,
                    distanceSeconds: (rawLandmark["distance_seconds"] as? NSNumber)?.doubleValue ?? 5,
                    step: stepNumber,
                    cameraHeadingDegrees: heading
                )
                notedNames.append(name)
            }
            return notedNames.isEmpty ? "nothing noted: each landmark needs a name and screen_x." : "on the map: \(notedNames.joined(separator: ", "))."

        case "walk_to_landmark":
            guard let gameMap, let name = text("name") else { return "error: walk_to_landmark needs a landmark name in game mode." }
            guard let route = gameMap.route(toLandmarkNamed: name) else {
                return "\(name) isn't on the map yet. find it (look_around), note it with note_landmarks, then walk to it."
            }
            onProgress?(stepNumber, "heading to \(route.landmark.name)")
            let displayFrame = screen.displayFrame
            if abs(route.turnDegrees) > 8 {
                await DottieScreenActionPerformer.moveMouse(
                    from: CGPoint(x: displayFrame.midX, y: displayFrame.midY),
                    deltaX: route.turnMousePoints, deltaY: 0, button: text("button")?.lowercased() ?? "right", seconds: 0.45
                )
                gameMap.noteCameraTurn(mousePoints: route.turnMousePoints)
            }
            // Stop a little short; the last bit is done by looking.
            var secondsLeft = min(max(route.walkSeconds - 0.6, 0), 12)
            while secondsLeft > 0.1 {
                if Task.isCancelled { return "stopped." }
                let burst = min(secondsLeft, 4)
                _ = await DottieScreenActionPerformer.hold(keyCombination: "w", seconds: burst)
                gameMap.noteMovement(keys: "w", seconds: burst)
                secondsLeft -= burst
            }
            return "turned \(Int(route.turnDegrees))° and walked about \(Int(route.walkSeconds.rounded()))s toward \(route.landmark.name). look at the screen: if it's close, finish with walk_to; if it's not where expected, note it again where you see it."

        case "look_around":
            guard let gameMap else { return "look_around is for game mode." }
            let button = text("button")?.lowercased() ?? "right"
            let quarterTurnPoints = CGFloat(90 / max(gameMap.degreesPerMousePoint, 0.01))
            let displayFrame = screen.displayFrame
            lookAroundHeadings = []
            onProgress?(stepNumber, "looking around")
            for viewNumber in 1...4 {
                if Task.isCancelled { return "stopped." }
                await DottieScreenActionPerformer.moveMouse(
                    from: CGPoint(x: displayFrame.midX, y: displayFrame.midY),
                    deltaX: quarterTurnPoints, deltaY: 0, button: button, seconds: 0.35
                )
                gameMap.noteCameraTurn(mousePoints: quarterTurnPoints)
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard viewNumber < 4 else { break }   // the 4th turn is back to the start
                lookAroundHeadings.append(gameMap.headingDegrees)
                if let viewImage = await DottieDisplayCapture.captureImage(displayFrame: displayFrame, maximumDimension: 768),
                   let viewJPEG = NSBitmapImageRep(cgImage: viewImage).representation(using: .jpeg, properties: [.compressionFactor: 0.7]) {
                    pendingExtraImageParts.append(["text": "Look-around view \(viewNumber): the camera turned \(viewNumber * 90)° right of where it started."])
                    pendingExtraImageParts.append(["inlineData": ["mimeType": "image/jpeg", "data": viewJPEG.base64EncodedString()]])
                }
            }
            return "turned all the way around. views 1-3 (90°, 180°, 270° right) come with the next screenshot, which faces the start direction again. note everything useful in all of them with note_landmarks (view 1-3 for those, 0 for the main screenshot), then plan your route from the map."

        case "save_picture":
            let name = text("name") ?? "picture"
            var pictureImage = screen.image
            if let box = arguments["box_2d"] as? [Any] {
                let numbers = box.compactMap { ($0 as? NSNumber)?.doubleValue }
                if numbers.count == 4, numbers[2] > numbers[0], numbers[3] > numbers[1] {
                    let imageWidth = Double(screen.image.width), imageHeight = Double(screen.image.height)
                    // A little of the surroundings helps recognize it later.
                    let padding = 0.15
                    let boxWidth = numbers[3] - numbers[1], boxHeight = numbers[2] - numbers[0]
                    let cropRect = CGRect(
                        x: max(0, (numbers[1] - boxWidth * padding) / 1000 * imageWidth),
                        y: max(0, (numbers[0] - boxHeight * padding) / 1000 * imageHeight),
                        width: boxWidth * (1 + 2 * padding) / 1000 * imageWidth,
                        height: boxHeight * (1 + 2 * padding) / 1000 * imageHeight
                    ).integral
                    if let croppedImage = screen.image.cropping(to: cropRect) { pictureImage = croppedImage }
                }
            }
            guard let pngData = NSBitmapImageRep(cgImage: pictureImage).representation(using: .png, properties: [:]) else {
                return "couldn't save the picture."
            }
            onProgress?(stepNumber, "remembering \(name)")
            return onSavePicture?(pngData, name, text("description") ?? "") ?? "pictures can't be saved right now."

        case "wait_for_video_end":
            let maximumSeconds = (arguments["max_seconds"] as? NSNumber)?.doubleValue ?? 600
            onProgress?(stepNumber, "watching the video to the end")
            return await DottieBrowser.waitForVideoToEnd(maximumSeconds: maximumSeconds)

        default:
            return "error: unknown action \(functionName)"
        }
    }

    /// Walks the character toward a target, from both boxes on the
    /// screenshot. Gemini is good at boxes and bad at judging how long to
    /// hold a key, so Dottie works out the keys and times herself, and
    /// learns the game's walking speed as it goes.
    private func walk(arguments: [String: Any], screen: DottieDisplayCapture.Screenshot, stepNumber: Int) async -> String {
        func frame(_ key: String) -> CGRect? {
            guard let numbers = (arguments[key] as? [Any])?.compactMap({ ($0 as? NSNumber)?.doubleValue }), numbers.count == 4,
                  numbers[2] >= numbers[0], numbers[3] >= numbers[1] else { return nil }
            let topLeft = screen.globalPoint(normalizedX: numbers[1], normalizedY: numbers[0])
            let bottomRight = screen.globalPoint(normalizedX: numbers[3], normalizedY: numbers[2])
            return CGRect(x: topLeft.x, y: bottomRight.y, width: bottomRight.x - topLeft.x, height: topLeft.y - bottomRight.y)
        }
        guard let targetFrame = frame("target_box_2d") else { return "error: target_box_2d must be [ymin, xmin, ymax, xmax]" }
        let target = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
        let view = (arguments["view"] as? String)?.lowercased() ?? "top_down"
        onProgress?(stepNumber, "walking over")

        if view == "behind" {
            // Third person: turn until the target is ahead, then walk.
            let displayFrame = screen.displayFrame
            let offset = (target.x - displayFrame.midX) / displayFrame.width
            if abs(offset) > 0.08 {
                // With a measured camera speed, turn exactly; else nudge.
                let turnPoints = gameMap.map { map -> CGFloat in
                    CGFloat(Double(offset) * DottieGameMap.horizontalFieldOfViewDegrees / max(map.degreesPerMousePoint, 0.01))
                } ?? offset * displayFrame.width * 0.6
                await DottieScreenActionPerformer.moveMouse(
                    from: CGPoint(x: displayFrame.midX, y: displayFrame.midY),
                    deltaX: turnPoints, deltaY: 0, button: "right", seconds: 0.35
                )
                gameMap?.noteCameraTurn(mousePoints: turnPoints)
                return "turned \(offset > 0 ? "right" : "left") toward it; look again and walk_to once it's ahead"
            }
            let heightShare = targetFrame.height / displayFrame.height
            if heightShare > 0.22 {
                return "it's right in front of the character: pick it up or use it (press_keys e, or click it)"
            }
            let seconds = min(2.0, max(0.4, 0.12 / max(heightShare, 0.01)))
            _ = await DottieScreenActionPerformer.hold(keyCombination: "w", seconds: seconds)
            gameMap?.noteMovement(keys: "w", seconds: seconds)
            return "walked forward for \(String(format: "%.1f", seconds))s; look again"
        }

        guard let playerFrame = frame("player_box_2d") else { return "error: top-down walking needs player_box_2d" }
        let player = CGPoint(x: playerFrame.midX, y: playerFrame.midY)
        // Learn the real speed from where the last walk ended up.
        if let lastWalk, lastWalk.plannedDistance > 30 {
            let moved = CGVector(dx: player.x - lastWalk.start.x, dy: player.y - lastWalk.start.y)
            let movedAlongPlan = moved.dx * lastWalk.plannedDirection.dx + moved.dy * lastWalk.plannedDirection.dy
            let ratio = min(max(movedAlongPlan / lastWalk.plannedDistance, 0.3), 3)
            walkSpeedPointsPerSecond = min(max(walkSpeedPointsPerSecond * ratio, 40), 2000)
        }
        let deltaX = target.x - player.x
        let deltaY = target.y - player.y
        let distance = hypot(deltaX, deltaY)
        let reach = max(16, (playerFrame.width + targetFrame.width) / 2)
        if distance <= reach {
            lastWalk = nil
            return "the character is on it: pick it up or use it now (press_keys e, or click it)"
        }
        // Each axis on its own key, both held at once for the shorter time.
        let horizontalSeconds = min(Double(abs(deltaX) / walkSpeedPointsPerSecond), 2.5)
        let verticalSeconds = min(Double(abs(deltaY) / walkSpeedPointsPerSecond), 2.5)
        let horizontalKey = deltaX > 0 ? "d" : "a"
        let verticalKey = deltaY > 0 ? "w" : "s"
        let bothSeconds = min(horizontalSeconds, verticalSeconds)
        if bothSeconds > 0.05 {
            _ = await DottieScreenActionPerformer.hold(keyCombination: "\(horizontalKey)+\(verticalKey)", seconds: bothSeconds)
        }
        let restSeconds = abs(horizontalSeconds - verticalSeconds)
        if restSeconds > 0.05 {
            _ = await DottieScreenActionPerformer.hold(keyCombination: horizontalSeconds > verticalSeconds ? horizontalKey : verticalKey, seconds: restSeconds)
        }
        let plannedMove = CGVector(
            dx: CGFloat(horizontalSeconds) * walkSpeedPointsPerSecond * (deltaX > 0 ? 1 : -1),
            dy: CGFloat(verticalSeconds) * walkSpeedPointsPerSecond * (deltaY > 0 ? 1 : -1)
        )
        let plannedDistance = hypot(plannedMove.dx, plannedMove.dy)
        lastWalk = plannedDistance > 0
            ? (player, plannedDistance, CGVector(dx: plannedMove.dx / plannedDistance, dy: plannedMove.dy / plannedDistance))
            : nil
        return "walked toward it (\(Int(distance)) points away before moving); look again and walk_to again until you're on it"
    }

    /// Brings a running app forward, else launches it by name.
    private static func openApplication(named appName: String) async -> Bool {
        let wantedName = appName.lowercased().replacingOccurrences(of: ".app", with: "")
        if let runningApplication = NSWorkspace.shared.runningApplications.first(where: {
            $0.activationPolicy == .regular && ($0.localizedName?.lowercased() == wantedName)
        }) {
            runningApplication.unhide()
            return runningApplication.activate(options: [.activateAllWindows])
        }
        guard let applicationURL = applicationURL(named: appName) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return (try? await NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration)) != nil
    }

    private static func open(_ url: URL, inApplicationNamed appName: String) async -> Bool {
        guard let applicationURL = applicationURL(named: appName) else { return NSWorkspace.shared.open(url) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return (try? await NSWorkspace.shared.open([url], withApplicationAt: applicationURL, configuration: configuration)) != nil
    }

    /// Finds an installed app by name in the usual folders ("opera" finds
    /// Opera GX.app too).
    private static func applicationURL(named appName: String) -> URL? {
        let wantedName = appName.lowercased().replacingOccurrences(of: ".app", with: "").trimmingCharacters(in: .whitespaces)
        let searchFolders = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        ]
        var prefixMatch: URL?
        for folder in searchFolders {
            guard let folderItems = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for itemURL in folderItems where itemURL.pathExtension == "app" {
                let itemName = itemURL.deletingPathExtension().lastPathComponent.lowercased()
                if itemName == wantedName { return itemURL }
                if prefixMatch == nil && itemName.hasPrefix(wantedName) { prefixMatch = itemURL }
            }
        }
        return prefixMatch
    }

    /// "Frontmost app: Opera GX, window: Kaggle - Competitions."
    /// Which game a job is in: the app's name and its window's title.
    private static func currentGameName() -> String {
        let applicationName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "game"
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else { return applicationName }
        let applicationElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)
        var focusedWindowValue: CFTypeRef?
        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(applicationElement, kAXFocusedWindowAttribute as CFString, &focusedWindowValue) == .success,
              let focusedWindowValue, CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID(),
              AXUIElementCopyAttributeValue(focusedWindowValue as! AXUIElement, kAXTitleAttribute as CFString, &titleValue) == .success,
              let windowTitle = titleValue as? String, !windowTitle.isEmpty, windowTitle != applicationName else {
            return applicationName
        }
        return "\(applicationName) \(windowTitle)"
    }

    private static func describeFrontmostWindow() -> String {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else { return "" }
        var description = "Frontmost app: \(frontmostApplication.localizedName ?? "unknown")"
        let applicationElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)
        var focusedWindowValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(applicationElement, kAXFocusedWindowAttribute as CFString, &focusedWindowValue) == .success,
           let focusedWindowValue, CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID() {
            var titleValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(focusedWindowValue as! AXUIElement, kAXTitleAttribute as CFString, &titleValue) == .success,
               let title = titleValue as? String, !title.isEmpty {
                description += ", window: \(title.prefix(120))"
            }
        }
        return description + "."
    }

    // MARK: - Gemini

    private static let systemInstruction = """
    You operate the user's Mac to finish a task they asked for, one or a few actions at a time. Each turn you get a fresh screenshot of the screen they're working on; reply only with function calls.

    How to work:
    - Look at the screenshot carefully before acting. Click things by their box on the screenshot (box_2d: [ymin, xmin, ymax, xmax], 0-1000 across the image).
    - To use an app, call open_app with its name (it comes to the front). To visit a site in a browser that's already open, click its address bar (or press cmd+l), type the address or search and press return. If the user named a browser, use that browser.
    - To type into a field, pass the field's box_2d to type_text so it's clicked first; use press_enter to submit.
    - Prefer keyboard shortcuts when one exists, they never miss: close tab cmd+w, new tab cmd+t, reopen closed tab cmd+shift+t, next/previous tab ctrl+tab / ctrl+shift+tab, address bar cmd+l, reload cmd+r, back cmd+[, find cmd+f, close window cmd+shift+w.
    - After an action that loads something, the next screenshot shows the result; use wait if it's still loading.
    - Scroll to find things that aren't visible. Prefer obvious, direct paths: menus, tabs, search boxes, profile pages.
    - Every turn, check the new screenshot against the task before acting: what's already done? If the step you were on already happened (the chat is open, the text is typed, the page loaded), move on to the next step instead of doing it again.
    - To watch a video or reel once (\"watch it, then like it\"), start it, call wait_for_video_end, and go on when it returns.
    - Expect hiccups: popups and cookie banners (close them or press escape), slow pages (wait once, then reload or go another way), search results that don't show (press return, or click the result that's there), things not where you expected (scroll, use the app's search, or its menu bar). If an action didn't change the screen, never repeat it as is: try something else.
    - When the task is done, call finish with the answer for the user: one or two short, plain sentences with the actual result (like "you're ranked 312th in the RSNA knee competition"). Also call finish if you can't go on (it needs a login, a captcha, or something is missing), saying why.

    Safety:
    - Never type passwords or payment details, and never sign in for the user.
    - Don't buy anything, send or post messages, delete things, or change account settings unless the task explicitly asks for exactly that.
    - Stay on the task; don't open unrelated things.
    """

    private static let gameInstruction = """

    Game mode: the user asked you to play or do something inside a video game. It's live, so act in short bursts and look again:
    - To get to something, call walk_to with the character's box and the target's box: Dottie works out which keys to hold and for how long, and learns the game's speed. Keep calling walk_to (with fresh boxes each turn) until it says you're on it, then pick up or use the thing (press_keys e, or click it). view is top_down when the camera looks down on the map (w moves up the screen), behind when it's a 3D camera behind the character.
    - Other movement with hold_keys: w forward, s back, a and d sideways, space jump, w+shift to sprint, for 0.2-2 seconds at a time. Single presses (e to pick up or interact, 1-9 for hotbar slots, space to jump) use press_keys.
    - Turn the camera with move_mouse: in Roblox and most third-person games hold the right button (button "right"); in first-person games where the mouse turns the view, use button "none". dx 100 is about a tenth of the screen; positive dx turns right, positive dy looks down.
    - Click on-screen buttons, menus and items with click. If keys seem to do nothing, click the game once to focus it.
    - Reference pictures show the exact items the user means: match them by shape and color, not just by name.
    - Map memory (3D games with a camera behind the character): at the start, call look_around once and note_landmarks for everything useful in all views. Dottie tracks every move and turn, so each step tells you where your landmarks are from where you stand. To go somewhere you've noted, use walk_to_landmark instead of turning and looking again; when it's close and visible, finish with walk_to. Note new things as you see them, and note a thing again when you see it somewhere other than the map says. Use zoom for small or faraway things.
    - One or two actions per turn. If nothing changes after several tries, try another way (jump, go around, turn), and finish saying what blocked you if you can't get there.
    - Never spend real money or in-game currency (Robux, gems), trade, or chat with other players unless the task says exactly that.
    """

    private static var gameFunctionDeclarations: [[String: Any]] {
        let boxProperty: [String: Any] = [
            "type": "array",
            "items": ["type": "integer"],
            "description": "[ymin, xmin, ymax, xmax] on the latest screenshot, each 0-1000."
        ]
        return [
            [
                "name": "walk_to",
                "description": "Walk the player's character to something in the game. Give the character's box and the target's box on the latest screenshot; Dottie holds the right keys for the right time. Call again each turn with fresh boxes until it says you're on it.",
                "parameters": ["type": "object", "properties": [
                    "player_box_2d": boxProperty,
                    "target_box_2d": boxProperty,
                    "view": ["type": "string", "enum": ["top_down", "behind"], "description": "top_down when the camera looks down on the map; behind for a 3D camera behind the character."]
                ], "required": ["target_box_2d", "view"]]
            ],
            [
                "name": "hold_keys",
                "description": "Hold keys down together for a while, to move in a game: 'w' to walk forward, 'w+shift' to sprint, 'a', 'd', 's', 'space'.",
                "parameters": ["type": "object", "properties": [
                    "keys": ["type": "string"],
                    "seconds": ["type": "number", "description": "0.05-5; short bursts of 0.2-2 work best."]
                ], "required": ["keys", "seconds"]]
            ],
            [
                "name": "move_mouse",
                "description": "Move the mouse to turn the camera or aim in a game. dx and dy are 0-1000 across the screenshot (100 is a tenth of the screen); positive dx turns right, positive dy looks down.",
                "parameters": ["type": "object", "properties": [
                    "dx": ["type": "integer"],
                    "dy": ["type": "integer"],
                    "button": ["type": "string", "enum": ["right", "left", "none"], "description": "right for Roblox and most third-person games, none for first-person mouse look."],
                    "seconds": ["type": "number", "description": "How long the move takes, 0.1-3; default 0.4."],
                    "box_2d": [
                        "type": "array",
                        "items": ["type": "integer"],
                        "description": "Where to start the move; leave out for the middle of the screen."
                    ]
                ], "required": ["dx", "dy", "button"]]
            ],
            [
                "name": "note_landmarks",
                "description": "Put things you see on your map of the game (shops, machines, doors, items, paths, players' bases), so you know where they are after turning away. Note anything you may need to go back to, from the main screenshot or a look-around view.",
                "parameters": ["type": "object", "properties": [
                    "landmarks": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "name": ["type": "string", "description": "Short name, like 'golem machine'."],
                                "description": ["type": "string", "description": "How it looks, to spot it again."],
                                "screen_x": ["type": "number", "description": "Where its middle is across that view, 0 (left) to 1000 (right)."],
                                "distance_seconds": ["type": "number", "description": "Roughly how many seconds of walking to reach it."],
                                "view": ["type": "integer", "description": "0 for the main screenshot, 1-3 for a look-around view."]
                            ],
                            "required": ["name", "screen_x", "distance_seconds"]
                        ]
                    ]
                ], "required": ["landmarks"]]
            ],
            [
                "name": "walk_to_landmark",
                "description": "Turn toward a landmark on your map and walk there in one go (behind-camera games). Then look and finish the last bit with walk_to.",
                "parameters": ["type": "object", "properties": [
                    "name": ["type": "string"],
                    "button": ["type": "string", "enum": ["right", "none"], "description": "Mouse button for turning the camera: right for Roblox, none for first-person."]
                ], "required": ["name"]]
            ],
            [
                "name": "look_around",
                "description": "Turn the camera all the way around in four quarter turns and get a picture of each direction, to see the whole area at once and fill in your map. Do it once at the start of a 3D game, or when you're lost.",
                "parameters": ["type": "object", "properties": [
                    "button": ["type": "string", "enum": ["right", "none"], "description": "right for Roblox and most third-person games, none for first-person."]
                ]]
            ]
        ]
    }

    private static var functionDeclarations: [[String: Any]] {
        let boxProperty: [String: Any] = [
            "type": "array",
            "items": ["type": "integer"],
            "description": "[ymin, xmin, ymax, xmax] of the element on the latest screenshot, each 0-1000."
        ]
        return [
            [
                "name": "open_app",
                "description": "Open a Mac app by name, or bring it to the front if it's already running.",
                "parameters": ["type": "object", "properties": ["name": ["type": "string", "description": "The app's name, like 'Opera GX', 'Safari', 'Notes'."]], "required": ["name"]]
            ],
            [
                "name": "open_url",
                "description": "Open a web address in a new tab.",
                "parameters": ["type": "object", "properties": [
                    "url": ["type": "string"],
                    "browser": ["type": "string", "description": "Browser app to use if the user named one, like 'Opera GX'. Leave out for the default browser."]
                ], "required": ["url"]]
            ],
            [
                "name": "click",
                "description": "Click an element on the latest screenshot.",
                "parameters": ["type": "object", "properties": [
                    "box_2d": boxProperty,
                    "label": ["type": "string", "description": "The element's visible text or a short name."],
                    "double_click": ["type": "boolean"],
                    "right_click": ["type": "boolean"]
                ], "required": ["box_2d", "label"]]
            ],
            [
                "name": "type_text",
                "description": "Type text. With box_2d, clicks that field first; otherwise types into whatever is focused.",
                "parameters": ["type": "object", "properties": [
                    "text": ["type": "string"],
                    "box_2d": boxProperty,
                    "select_all_first": ["type": "boolean", "description": "Replace what's already in the field."],
                    "press_enter": ["type": "boolean", "description": "Press return after typing, to submit or search."]
                ], "required": ["text"]]
            ],
            [
                "name": "press_keys",
                "description": "Press a key or shortcut, like 'enter', 'escape', 'tab', 'cmd+l', 'cmd+t', 'cmd+[' (back).",
                "parameters": ["type": "object", "properties": ["keys": ["type": "string"]], "required": ["keys"]]
            ],
            [
                "name": "scroll",
                "description": "Scroll the content under box_2d (or the middle of the screen).",
                "parameters": ["type": "object", "properties": [
                    "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
                    "amount": ["type": "integer", "description": "1-10; about 5 is a screenful."],
                    "box_2d": boxProperty
                ], "required": ["direction"]]
            ],
            [
                "name": "wait",
                "description": "Wait for something to load (a few seconds), or up to 120 seconds when you know how long something takes.",
                "parameters": ["type": "object", "properties": ["seconds": ["type": "number"]], "required": ["seconds"]]
            ],
            [
                "name": "zoom",
                "description": "Take a closer, sharper look at part of the screen (small text, icons, items far away). The close-up comes with the next screenshot.",
                "parameters": ["type": "object", "properties": ["box_2d": boxProperty], "required": ["box_2d"]]
            ],
            [
                "name": "save_picture",
                "description": "Save a picture of something on the screen to remember it by name for later jobs (where a machine is on a game map, what an item looks like). Only when the task asks to remember something, or when it will clearly be needed again.",
                "parameters": ["type": "object", "properties": [
                    "name": ["type": "string", "description": "1-4 words, like 'roll machines'."],
                    "description": ["type": "string", "description": "What it is, where it's from (game or app, which area) and how it looks."],
                    "box_2d": boxProperty
                ], "required": ["name", "description"]]
            ],
            [
                "name": "wait_for_video_end",
                "description": "Wait until the video or reel playing in the browser has played through once (reels loop, so this notices when it starts over), then carry on. Use it when the task says to watch something, play it once, or do something after a video ends.",
                "parameters": ["type": "object", "properties": [
                    "max_seconds": ["type": "number", "description": "Give up after this long; default 600."]
                ]]
            ],
            [
                "name": "finish",
                "description": "End the task. answer is what Dottie tells the user: the result they asked for, or why it couldn't be done. One or two short sentences.",
                "parameters": ["type": "object", "properties": [
                    "answer": ["type": "string"],
                    "lesson": ["type": "string", "description": "One short tip for doing this kind of job in this app or site next time: the path that worked, or what to avoid. Leave empty if it was straightforward."]
                ], "required": ["answer"]]
            ]
        ]
    }

    private func requestNextActions(contents: [[String: Any]]) async throws -> [[String: Any]] {
        if isGameMode, let lastRequestStartedAt {
            let waitSeconds = Self.minimumGameRequestSpacingSeconds + lastRequestStartedAt.timeIntervalSinceNow
            if waitSeconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000))
            }
        }
        lastRequestStartedAt = Date()
        do {
            return try await requestNextActionsOnce(contents: contents)
        } catch let error as NSError where error.code == 400 && error.localizedDescription.localizedCaseInsensitiveContains("signature") {
            // The Worker answers with another model when the first is busy,
            // and Gemini 3 can reject a function call signed by a different
            // model. Google's documented placeholder skips that check.
            print("⚠️ Screen task: retrying without thought signatures")
            return try await requestNextActionsOnce(contents: Self.contentsWithPlaceholderSignatures(contents))
        }
    }

    private static func contentsWithPlaceholderSignatures(_ contents: [[String: Any]]) -> [[String: Any]] {
        contents.map { content in
            guard let parts = content["parts"] as? [[String: Any]] else { return content }
            var updatedContent = content
            updatedContent["parts"] = parts.map { part in
                guard part["thoughtSignature"] != nil else { return part }
                var updatedPart = part
                updatedPart["thoughtSignature"] = "skip_thought_signature_validator"
                return updatedPart
            }
            return updatedContent
        }
    }

    private func requestNextActionsOnce(contents: [[String: Any]]) async throws -> [[String: Any]] {
        var request = URLRequest(url: ClickyWorkerConfiguration.url(forRoute: "/chat"))
        request.httpMethod = "POST"
        // A step normally takes 2-8s. One stuck in Google's queue (seen at
        // 90s+) is dropped and asked again, which is usually much quicker.
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        ClickyWorkerConfiguration.applyAuthenticationHeaders(to: &request)
        var requestContents = contents
        if !referenceImageParts.isEmpty, var firstParts = requestContents.first?["parts"] as? [[String: Any]] {
            firstParts.insert(contentsOf: referenceImageParts, at: 0)
            requestContents[0]["parts"] = firstParts
        }
        let requestBody: [String: Any] = [
            "model": isGameMode ? Self.gameModel : Self.taskModel,
            "systemInstruction": ["parts": [["text": Self.systemInstruction + (isGameMode ? Self.gameInstruction : "")]]],
            "contents": requestContents,
            "tools": [["functionDeclarations": Self.functionDeclarations + (isGameMode ? Self.gameFunctionDeclarations : [])]],
            "toolConfig": ["functionCallingConfig": ["mode": "ANY"]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (responseData, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard statusCode == 200 else {
            throw NSError(domain: "DottieScreenTaskRunner", code: statusCode, userInfo: [
                NSLocalizedDescriptionKey: "Gemini returned \(statusCode): \(String(decoding: responseData.prefix(300), as: UTF8.self))"
            ])
        }

        // /chat streams server-sent events; gather every part, keeping each
        // function call whole with its thought signature (Gemini needs it
        // back on the next turn).
        let modelParts = GeminiServerSentEvents.parts(from: responseData)
        guard !modelParts.isEmpty else {
            throw NSError(domain: "DottieScreenTaskRunner", code: -2, userInfo: [NSLocalizedDescriptionKey: "empty answer"])
        }
        return modelParts
    }

    /// Keeps only the newest screenshots in the conversation.
    private static func dropOldScreenshots(from contents: inout [[String: Any]]) {
        var screenshotsSeen = 0
        for contentIndex in contents.indices.reversed() {
            guard var parts = contents[contentIndex]["parts"] as? [[String: Any]] else { continue }
            var didChange = false
            for partIndex in parts.indices.reversed() where parts[partIndex]["inlineData"] != nil {
                screenshotsSeen += 1
                if screenshotsSeen > keptScreenshotCount {
                    parts[partIndex] = ["text": "(older screenshot removed)"]
                    didChange = true
                }
            }
            if didChange {
                contents[contentIndex]["parts"] = parts
            }
        }
    }
}

// MARK: - Screen capture

/// One display captured without Dottie's own windows (cursor, notch,
/// drawings), with what's needed to map 0-1000 positions back to the screen.
@MainActor
enum DottieDisplayCapture {
    struct Screenshot {
        let image: CGImage
        let jpegData: Data
        /// The display's frame in global AppKit coordinates.
        let displayFrame: CGRect

        /// A 0-1000 position on the screenshot, in global AppKit points.
        func globalPoint(normalizedX: Double, normalizedY: Double) -> CGPoint {
            let clampedX = min(max(normalizedX, 0), 1000) / 1000
            let clampedY = min(max(normalizedY, 0), 1000) / 1000
            return CGPoint(
                x: displayFrame.minX + CGFloat(clampedX) * displayFrame.width,
                y: displayFrame.maxY - CGFloat(clampedY) * displayFrame.height
            )
        }
    }

    /// The display with the frontmost app's window, else the one with the
    /// pointer.
    static func captureActiveDisplay(maximumDimension: Int) async -> Screenshot? {
        let displayFrame = frontmostWindowDisplayFrame()
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })?.frame
            ?? NSScreen.main?.frame
        guard let displayFrame else { return nil }
        return await capture(displayFrame: displayFrame, maximumDimension: maximumDimension)
    }

    static func capture(displayFrame: CGRect, maximumDimension: Int) async -> Screenshot? {
        guard let image = await captureImage(displayFrame: displayFrame, maximumDimension: maximumDimension),
              let jpegData = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            return nil
        }
        return Screenshot(image: image, jpegData: jpegData, displayFrame: displayFrame)
    }

    static func captureImage(displayFrame: CGRect, maximumDimension: Int) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return nil }

        let matchingScreen = NSScreen.screens.first(where: { $0.frame == displayFrame })
        let displayID = matchingScreen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else { return nil }

        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == ownBundleIdentifier }
        let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)

        let configuration = SCStreamConfiguration()
        let pointsToPixels = matchingScreen?.backingScaleFactor ?? 2
        let nativeWidth = CGFloat(display.width) * pointsToPixels
        let nativeHeight = CGFloat(display.height) * pointsToPixels
        let downscale = min(1, CGFloat(maximumDimension) / max(nativeWidth, nativeHeight))
        configuration.width = Int(nativeWidth * downscale)
        configuration.height = Int(nativeHeight * downscale)
        configuration.showsCursor = false

        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    private static func frontmostWindowDisplayFrame() -> CGRect? {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else { return nil }
        let applicationElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)
        var focusedWindowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(applicationElement, kAXFocusedWindowAttribute as CFString, &focusedWindowValue) == .success,
              let focusedWindowValue, CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID() else { return nil }
        let focusedWindow = focusedWindowValue as! AXUIElement
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focusedWindow, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(focusedWindow, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        // Accessibility is top-left origin on the primary display.
        let primaryDisplayHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let windowCenter = CGPoint(x: position.x + size.width / 2, y: primaryDisplayHeight - (position.y + size.height / 2))
        return NSScreen.screens.first(where: { $0.frame.contains(windowCenter) })?.frame
    }
}
