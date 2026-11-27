//
//  DottieWatchAndLearn.swift
//  leanring-buddy
//
//  Watch and learn: "watch me do this for 30 seconds", "watch me add a
//  patient", "let me show you around OpenEMR". While the user works, Dottie
//  keeps a frame of the screen every two seconds (in a temporary folder,
//  deleted once she's learned) and the clicks, typing, hovers and app
//  switches the smart-replay recorder notices (no passwords, and private
//  details like an SSN, birth date or phone number never reach the model).
//  Lines typed as "NOTE: …" are read as the person explaining the screen.
//  A tour runs until "done" (15 minutes at most) and is cut into parts at
//  each new page or note, with the screen's words read on the Mac, for at
//  most six text calls. At the end Claude (the Worker's model when Claude
//  isn't there) writes down, in words, what the user was doing and how: the
//  goal, the method, the app's pages and where things are. Each separate
//  task it saw (adding a record, booking something) becomes a named app
//  task (DottieAppTasks) Dottie can do again step by step with new values,
//  and the pages it read go to app memory (the watch me review, 27 Nov).
//
//  Each how-to is kept in Application Support/Dottie/Watched/howtos.json
//  with the sites and apps it was watched in, and saved as a skill in the
//  skills library (turned on for every Dot), so screen jobs in the same
//  place and helpers both use it.
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
    /// "tour" for a whole app shown page by page; nil for one job.
    var kind: String? = nil
    /// The sites and apps (task place keys) it was watched in.
    var places: [String]? = nil
    /// The app's pages, as a tour explained them.
    var pages: [DottieWatchedHowToPage]? = nil
    /// Requests a person would say for the tasks it showed.
    var exampleRequests: [String]? = nil

    var isTour: Bool { kind == "tour" }

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

    /// A frame kept on disk while watching.
    private struct KeptFrame {
        let fileURL: URL
        let secondsIntoWatch: Double
    }

    /// The screen's words, read on the Mac on a new page or after a note.
    private struct ScreenReading {
        let secondsIntoWatch: Double
        let texts: [String]
    }

    private var keptFrames: [KeptFrame] = []
    private var frameFolderURL: URL?
    private var frameNumber = 0
    private var screenReadings: [ScreenReading] = []
    private var frameTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var startedAt: Date?
    private var userNote = ""
    private var isTour = false
    /// False when a smart replay was already being recorded, so stopping
    /// here doesn't end the user's recording.
    private var startedActionRecorder = false

    static let defaultSeconds = DottieWatchPlan.defaultSeconds
    static let maximumSeconds = DottieWatchPlan.maximumSeconds
    private static let frameIntervalSeconds: Double = 2

    /// The switch on Home → Smart Replays: off keeps typed text off the model's page.
    static var sendsTypedText: Bool {
        UserDefaults.standard.object(forKey: DottieWatchPlan.sendsTypedTextDefaultsKey) as? Bool ?? true
    }

    private let watcherBot = DottieClaudeBot(
        helperName: "Dottie Watcher",
        title: "Learns how the user does things by watching",
        instructions: DottieWatchPlan.watcherInstructions,
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

    /// Starts watching for `seconds` (a tour: until "done"), then learns.
    /// Returns a line to say.
    func start(seconds requestedSeconds: Int?, note: String?, isTour requestedTour: Bool = false) -> String {
        guard !isWatching else { return "already watching. say \"stop watching\" when done." }
        guard CGPreflightScreenCaptureAccess() else { return "Dottie needs Screen Recording permission to watch." }
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        isTour = requestedTour
        let length = DottieWatchPlan.watchLength(requestedSeconds: requestedSeconds, isTour: isTour)
        // The actions recorder is shared with smart replays; while one is
        // being recorded, only frames are kept, and the user is told.
        let recorder = DottieSmartReplayRecorder.shared
        let recorderWasBusy = recorder.isRecording
        startedActionRecorder = recorder.start(kind: .smart, isTour: isTour)
        let onlyFramesReason: String? = startedActionRecorder ? nil
            : (recorderWasBusy ? "a smart replay is being recorded" : "Dottie needs Accessibility access in System Settings, Privacy & Security")
        removeFramesLeftInTheWatcherFolder()
        isWatching = true
        keptFrames = []
        screenReadings = []
        frameNumber = 0
        frameFolderURL = Self.makeFrameFolder()
        startedAt = Date()
        userNote = trimmedNote
        statusLine = "Watching…"
        let context = DottieReplayContext.current()
        let looksMedical = DottieWatchPlan.looksMedical([trimmedNote, context.appName ?? "", context.siteHost ?? "", context.windowTitle ?? ""])
        let howToStopText = isTour ? "Say \u{201C}done\u{201D} when the tour is over." : "I'll stop in \(DottieWatchPlan.spokenDuration(length.seconds)), or say \u{201C}stop watching\u{201D}."
        onStatus?(isTour ? "Watching your tour" : "Watching you", "Do it as you normally would. \(howToStopText)")
        frameTask = Task { [weak self] in
            await self?.keepTakingFrames()
        }
        stopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(length.seconds) * 1_000_000_000)
            guard !Task.isCancelled, let self, self.isWatching else { return }
            _ = await self.stopAndLearn()
        }
        DottieLog.notice("🎓 Watching started (\(public: isTour ? "tour" : "one job"), \(public: length.seconds) s, actions \(public: startedActionRecorder ? "on" : "off"))")
        return DottieWatchPlan.startLine(length: length, isTour: isTour, onlyFramesReason: onlyFramesReason, looksMedical: looksMedical)
    }

    /// A frame every two seconds while watching, kept when the screen
    /// changed or a note was just typed, and the screen's words read on a
    /// new page.
    private func keepTakingFrames() async {
        var lastFingerprint: [UInt8]?
        var lastPageKey: String?
        var lastNarrationCount = 0
        while !Task.isCancelled, isWatching {
            if let screen = await DottieDisplayCapture.captureActiveDisplay(maximumDimension: 1280) {
                let fingerprint = Self.fingerprint(of: screen.image)
                let narrationCount = DottieSmartReplayRecorder.shared.narrationCount
                let wroteANote = narrationCount != lastNarrationCount
                lastNarrationCount = narrationCount
                if wroteANote || lastFingerprint.map({ !DottieWatchPlan.isSameScreen($0, fingerprint) }) ?? true {
                    keepFrame(screen.jpegData)
                }
                lastFingerprint = fingerprint
                lastPageKey = await readScreenIfNew(screen, wroteANote: wroteANote, lastPageKey: lastPageKey)
            }
            if let startedAt {
                statusLine = "Watching… \(Int(Date().timeIntervalSince(startedAt))) s"
            }
            try? await Task.sleep(nanoseconds: UInt64(Self.frameIntervalSeconds * 1_000_000_000))
        }
    }

    private func keepFrame(_ jpegData: Data) {
        guard let frameFolderURL, let startedAt else { return }
        frameNumber += 1
        let fileURL = frameFolderURL.appendingPathComponent("frame-\(frameNumber).jpg")
        guard (try? jpegData.write(to: fileURL, options: .atomic)) != nil else { return }
        keptFrames.append(KeptFrame(fileURL: fileURL, secondsIntoWatch: Date().timeIntervalSince(startedAt)))
        guard keptFrames.count > DottieWatchPlan.maximumFramesKept else { return }
        // Past the cap, frames are thinned over the whole watch, not just its start.
        let keptIndices = Set(DottieWatchPlan.evenlySpacedIndices(count: keptFrames.count, keeping: DottieWatchPlan.maximumFramesKept * 2 / 3))
        for (index, frame) in keptFrames.enumerated() where !keptIndices.contains(index) {
            try? FileManager.default.removeItem(at: frame.fileURL)
        }
        keptFrames = keptFrames.enumerated().filter { keptIndices.contains($0.offset) }.map(\.element)
    }

    /// On a new page, or after a typed note, the screen's words are read on
    /// the Mac (no model): for a tour's parts, and for app memory's pages
    /// (Wasee: app memory is on while Dottie watches). Returns the page.
    private func readScreenIfNew(_ screen: DottieDisplayCapture.Screenshot, wroteANote: Bool, lastPageKey: String?) async -> String? {
        let context = DottieReplayContext.current()
        let pageKey = [context.appBundleIdentifier ?? "", context.siteHost ?? "", DottieAppMemoryPlan.cleanedTitle(context.windowTitle ?? "")]
            .joined(separator: "|")
        guard wroteANote || pageKey != lastPageKey, let startedAt else { return pageKey }
        let elements = await DottieAppMemory.readElements(on: screen.image)
        let shownTexts = elements.map(\.label).filter { !DottieWatchPlan.looksPrivate(fieldLabel: nil, value: $0) }
        screenReadings.append(ScreenReading(secondsIntoWatch: Date().timeIntervalSince(startedAt), texts: shownTexts))
        if screenReadings.count > 200 { screenReadings.removeFirst() }
        if let page = DottieAppMemory.shared.frontPageWhileWatched(context: context) {
            DottieAppMemory.shared.notePageFromScreenJob(on: page, elements: elements)
        }
        return pageKey
    }

    private static func makeFrameFolder() -> URL? {
        let folderURL = FileManager.default.temporaryDirectory.appendingPathComponent("DottieWatch-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)) != nil else { return nil }
        return folderURL
    }

    /// Older versions left the last watch's frames in the watcher's folder.
    private func removeFramesLeftInTheWatcherFolder() {
        let fileNames = (try? FileManager.default.contentsOfDirectory(atPath: watcherBot.workspaceURL.path)) ?? []
        for fileName in fileNames where fileName.hasPrefix("watch-frame-") && fileName.hasSuffix(".jpg") {
            try? FileManager.default.removeItem(at: watcherBot.workspaceURL.appendingPathComponent(fileName))
        }
    }

    /// Stops watching and works out what the user did. Returns a line to say.
    func stopAndLearn() async -> String {
        guard isWatching else { return "not watching right now." }
        isWatching = false
        frameTask?.cancel()
        stopTask?.cancel()
        var actions: [DottieWatchedAction] = []
        var droppedActionCount = 0
        if startedActionRecorder {
            let recorder = DottieSmartReplayRecorder.shared
            _ = recorder.stop()
            actions = recorder.watchedActions
            droppedActionCount = recorder.droppedActionCount
        }
        startedActionRecorder = false
        let watchedFrames = keptFrames
        let readings = screenReadings
        // The frames are deleted once learned, whatever happens: screenshots
        // of the user's screen don't stay on disk.
        let folderToDelete = frameFolderURL
        frameFolderURL = nil
        keptFrames = []
        screenReadings = []
        defer {
            if let folderToDelete { try? FileManager.default.removeItem(at: folderToDelete) }
        }
        guard !watchedFrames.isEmpty else {
            statusLine = ""
            return "nothing was seen (no screen frames). say so."
        }
        statusLine = "Working out what you did…"
        onStatus?("Got it", isTour ? "Working out what your tour showed…" : "Working out what you were doing…")
        let frontContext = DottieReplayContext.current()
        guard let understanding = await understand(frames: watchedFrames, readings: readings, actions: actions,
                                                   droppedActionCount: droppedActionCount) else {
            statusLine = ""
            return "couldn't work out what the user was doing (the AI models didn't answer). say so and offer to watch again."
        }
        return keepWhatWasLearned(understanding, actions: actions, frontContext: frontContext)
    }

    // MARK: - Understanding

    /// One text call for a job; a tour's parts get one each (six at most),
    /// with a few of their frames and the words read on screen.
    private func understand(frames watchedFrames: [KeptFrame], readings: [ScreenReading], actions: [DottieWatchedAction],
                            droppedActionCount: Int) async -> DottieWatchPlan.Understanding? {
        let sendsTypedText = Self.sendsTypedText
        let frameSeconds = watchedFrames.map(\.secondsIntoWatch)
        let parts = isTour && !actions.isEmpty
            ? DottieWatchPlan.tourParts(of: actions)
            : [DottieWatchPlan.WatchPart(actionRange: 0..<actions.count, startSeconds: 0, endSeconds: frameSeconds.last ?? 0)]
        var understandings: [DottieWatchPlan.Understanding] = []
        for (partIndex, part) in parts.enumerated() {
            let pickedIndices = parts.count == 1
                ? DottieWatchPlan.evenlySpacedIndices(count: watchedFrames.count, keeping: DottieWatchPlan.framesSentForOneJob)
                : DottieWatchPlan.frameIndices(frameSeconds: frameSeconds, from: part.startSeconds, to: part.endSeconds,
                                               picking: DottieWatchPlan.framesSentPerTourPart)
            let pickedFrames = pickedIndices.compactMap { try? Data(contentsOf: watchedFrames[$0].fileURL) }
            let screenTexts = isTour ? Self.screenTexts(in: readings, from: part.startSeconds, to: part.endSeconds) : []
            let prompt = DottieWatchPlan.partPrompt(actions: actions, part: part, partNumber: partIndex + 1, partCount: parts.count,
                                                    screenTexts: screenTexts, note: userNote, sendsTypedText: sendsTypedText,
                                                    droppedActionCount: droppedActionCount)
            if parts.count > 1 { statusLine = "Working out part \(partIndex + 1) of \(parts.count)…" }
            if let reply = await askForUnderstanding(frames: pickedFrames, prompt: prompt),
               let understanding = DottieWatchPlan.understanding(from: reply) {
                understandings.append(understanding)
            }
        }
        DottieLog.notice("🎓 Watch understood in \(public: understandings.count) of \(public: parts.count) part(s)")
        return DottieWatchPlan.mergedUnderstanding(understandings)
    }

    /// The words read on screen during a part, each once.
    private static func screenTexts(in readings: [ScreenReading], from startSeconds: Double, to endSeconds: Double) -> [String] {
        var seenTexts = Set<String>()
        var texts: [String] = []
        for reading in readings where reading.secondsIntoWatch >= startSeconds - 1 && reading.secondsIntoWatch <= endSeconds + 2.5 {
            for text in reading.texts where seenTexts.insert(text.lowercased()).inserted {
                texts.append(text)
            }
        }
        return texts
    }

    /// Claude through the user's plan first (the frames as files, deleted
    /// right after), then the Worker's model.
    private func askForUnderstanding(frames pickedFrames: [Data], prompt: String) async -> [String: Any]? {
        if watcherBot.isWorthTrying {
            var frameLines: [String] = []
            var writtenFrameURLs: [URL] = []
            for (index, frameData) in pickedFrames.enumerated() {
                let frameURL = watcherBot.workspaceURL.appendingPathComponent("watch-frame-\(index + 1).jpg")
                if (try? frameData.write(to: frameURL, options: .atomic)) != nil {
                    frameLines.append("- `\(frameURL.path)`")
                    writtenFrameURLs.append(frameURL)
                }
            }
            let message = """
            Open these frames of the user's screen, in order, taken every few seconds while they worked:
            \(frameLines.joined(separator: "\n"))

            \(prompt)
            """
            let replyText = await watcherBot.send(message, newConversation: true, timeoutSeconds: 90)
            for frameURL in writtenFrameURLs {
                try? FileManager.default.removeItem(at: frameURL)
            }
            if let replyText, let reply = DottieClaudeBot.jsonObject(in: replyText) {
                return reply
            }
        }
        return await askWorker(frames: pickedFrames, prompt: prompt)
    }

    private func askWorker(frames pickedFrames: [Data], prompt: String) async -> [String: Any]? {
        var parts: [[String: Any]] = pickedFrames.map { frameData in
            ["inlineData": ["mimeType": "image/jpeg", "data": frameData.base64EncodedString()]]
        }
        parts.append(["text": "Those are frames of the user's screen, in order.\n\n" + prompt])
        var request = URLRequest(url: ClickyWorkerConfiguration.url(forRoute: "/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        ClickyWorkerConfiguration.applyAuthenticationHeaders(to: &request)
        let model = DottieModelPicker.normalModelName
        let requestBody: [String: Any] = [
            "model": model,
            "systemInstruction": ["parts": [["text": DottieWatchPlan.watcherInstructions]]],
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

    /// Saves the how-to (and its skill) and the tasks it showed. Returns
    /// the line to say.
    private func keepWhatWasLearned(_ understanding: DottieWatchPlan.Understanding, actions: [DottieWatchedAction],
                                    frontContext: DottieReplayContext) -> String {
        let actionPlaces = Array(Set(actions.map(\.placeKey).filter { !$0.isEmpty })).sorted()
        let frontPlace = frontContext.appBundleIdentifier.map { DottieAppTaskPlan.placeKey(siteHost: frontContext.siteHost, bundleIdentifier: $0) }
        let places = actionPlaces.isEmpty ? (frontPlace.map { [$0] } ?? []) : actionPlaces
        let exampleRequests = understanding.tasks.map(\.exampleRequest).filter { !$0.isEmpty }
        var howTo = DottieWatchedHowTo(
            learnedAt: Date(), name: understanding.name,
            appName: understanding.app.isEmpty ? (frontContext.siteHost ?? frontContext.appName ?? "") : understanding.app,
            summary: understanding.summary, goal: understanding.goal, method: understanding.method,
            interfaceNotes: understanding.interfaceNotes, worksFor: understanding.worksFor, skillName: nil,
            kind: isTour ? "tour" : nil, places: places, pages: understanding.pages.isEmpty ? nil : understanding.pages,
            exampleRequests: exampleRequests.isEmpty ? nil : exampleRequests
        )
        howTo.skillName = saveAsSkill(howTo)
        // The same job, or a tour of the same app, watched again replaces the old notes.
        howTos.removeAll { $0.name.lowercased() == howTo.name.lowercased() && $0.appName == howTo.appName && $0.isTour == howTo.isTour }
        howTos.append(howTo)
        save()
        let watchedTasks = DottieWatchPlan.appTasks(from: understanding, actions: actions, now: Date())
        let keptTaskCount = DottieAppTasks.shared.noteWatchedTasks(watchedTasks)
        statusLine = "Learned \(howTo.name)"
        onStatus?("Learned: \(howTo.name)", howTo.summary)
        DottieLog.notice("🎓 Learned by watching: \(public: understanding.pages.count) page(s), \(public: keptTaskCount) task(s) to do again")
        var line = "learned it. what you understood: \(howTo.summary)"
        if keptTaskCount > 0 {
            line += " Dottie can now do these by herself: " + watchedTasks.map(\.name).joined(separator: ", ") + "."
        }
        return line + " tell the user in one or two short lines what you understood, and that you can now do it, or similar jobs, by yourself."
    }

    // MARK: - Using what was learned

    /// The how-tos that fit a job, for its instructions, each trimmed (a
    /// tour sends only the pages that matter). "" when none.
    func howToText(forTask taskText: String, context: DottieReplayContext) -> String {
        let frontPlaceKey = context.appBundleIdentifier.map { DottieAppTaskPlan.placeKey(siteHost: context.siteHost, bundleIdentifier: $0) }
        let matchingHowTos = howTos.filter { howTo in
            DottieWatchPlan.howToFits(howTo, taskText: taskText, frontmostAppName: context.appName, frontPlaceKey: frontPlaceKey)
        }
        if !matchingHowTos.isEmpty {
            DottieLog.notice("🎓 Using \(public: matchingHowTos.count) learned how-to(s): \(public: matchingHowTos.map(\.name).joined(separator: ", "))")
        }
        return matchingHowTos.suffix(3)
            .map { DottieWatchPlan.promptText(for: $0, taskText: taskText, frontPageTitle: context.windowTitle) }
            .joined(separator: "\n\n")
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
        let pagesText = (howTo.pages ?? []).isEmpty ? "" : "\nPages:\n" + (howTo.pages ?? []).map { "- " + $0.line }.joined(separator: "\n")
        let instructions = """
        Learned by watching the user. Use this way for this job and similar ones (\(howTo.worksFor.isEmpty ? "the same kind of task" : howTo.worksFor)), adapting names and values to the new task.

        \(howTo.promptText)\(pagesText)
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

    private static func fingerprint(of image: CGImage) -> [UInt8] {
        let width = DottieWatchPlan.fingerprintWidth, height = DottieWatchPlan.fingerprintHeight
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return pixels }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
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
                description: "Watch the user do a job on their Mac for a while (default 30 seconds, up to 15 minutes) and understand it in words, so Dottie can later do that job, or similar ones, by herself: 'watch me do this', 'watch me add a patient', 'learn how I do my spreadsheet'. For a tour of a whole app ('let me show you around OpenEMR') use mode tour: it watches until they say done and learns every page and task it shows. start begins watching (seconds, note: what they said the job is, mode); stop ends early and learns; list says what was learned; forget removes one by name. After learning, similar screen jobs and helpers use it on their own.",
                parameters: [
                    "type": "OBJECT",
                    "properties": [
                        "action": ["type": "STRING", "enum": ["start", "stop", "list", "forget"]],
                        "seconds": ["type": "NUMBER", "description": "For start: how long to watch, if they said (5 to 900)."],
                        "note": ["type": "STRING", "description": "For start: what they said the job is. For forget: its name."],
                        "mode": ["type": "STRING", "enum": ["job", "tour"], "description": "For start: tour for showing a whole app until done."]
                    ],
                    "required": ["action"]
                ],
                audiences: [.voice]
            ) { arguments in
                let watcher = DottieWatchAndLearn.shared
                switch arguments.dottieString("action") ?? "list" {
                case "start":
                    let seconds = arguments.dottieNumber("seconds").map { Int($0) }
                    return watcher.start(seconds: seconds, note: arguments.dottieString("note"), isTour: arguments.dottieString("mode") == "tour")
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
