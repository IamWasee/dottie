//
//  DottieSelfCheck.swift
//  leanring-buddy
//
//  "Check everything": one button in Settings (and the self_check voice
//  tool) that tries every part Dottie depends on and says, in plain words,
//  what works, what's slow and what's broken, with a one-tap fix where
//  there is one.
//
//  Checks: permissions, the Worker (and how quick it is), one tiny Gemini
//  answer, a voice (Live) token, a second of microphone sound, reading the
//  frontmost app with Accessibility, a screenshot, the bundled cua-driver,
//  the helpers' runtime (plus the openmausbot and claude command-line
//  tools if installed), the Telegram bridge, and Apple's on-device model.
//

import AppKit
import ApplicationServices
import AVFoundation
import Combine
import Foundation

@MainActor
final class DottieSelfCheck: ObservableObject {
    static let shared = DottieSelfCheck()

    enum Level: Int, Comparable {
        case good, off, warning, problem
        static func < (first: Level, second: Level) -> Bool { first.rawValue < second.rawValue }
    }

    enum Fix {
        case openURL(URL)
        case askPermission(DottiePermissions.Kind)
        case installHelperRuntime
        case checkAgain
    }

    struct Item: Identifiable {
        let id: String
        let title: String
        let level: Level
        let detail: String
        var fix: Fix?
        var fixLabel: String?
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var isRunning = false
    @Published private(set) var lastRunAt: Date?
    /// Set by CompanionManager so the Telegram bridge can be checked.
    weak var phoneBridge: DottiePhoneBridge?

    // MARK: - Running

    /// Runs every check (about 3-6 seconds) and returns a short summary.
    @discardableResult
    func run() async -> String {
        guard !isRunning else { return "already checking." }
        isRunning = true
        items = []
        defer {
            isRunning = false
            lastRunAt = Date()
        }

        // The network checks and the microphone run side by side.
        async let workerItems = Self.checkWorker()
        async let microphoneItem = checkMicrophone()
        async let toolItems = Self.checkCommandLineTools()

        add(contentsOf: await checkPermissions())
        add(checkAccessibilityReading())
        add(await checkScreenCapture())
        add(contentsOf: await workerItems)
        add(await microphoneItem)
        add(contentsOf: await toolItems)
        add(checkTelegram())
        add(checkOnDeviceModel())
        add(Item(id: "models", title: "Gemini models", level: .off, detail: DottieModelPicker.shared.summary()))
        return summary
    }

    private func add(_ item: Item) { items.append(item) }
    private func add(contentsOf newItems: [Item]) { items.append(contentsOf: newItems) }

    /// "All 14 checks passed." or what needs a look.
    var summary: String {
        let needsLook = items.filter { $0.level >= .warning }
        guard !needsLook.isEmpty else { return "everything works (\(items.count) checks passed)." }
        let lines = needsLook.sorted { $0.level > $1.level }.map { "\($0.title): \($0.detail)" }
        return "\(items.count - needsLook.count) of \(items.count) checks are fine. needs a look: " + lines.joined(separator: " | ")
    }

    func apply(_ fix: Fix) {
        switch fix {
        case .openURL(let url):
            NSWorkspace.shared.open(url)
        case .askPermission(let kind):
            Task {
                await DottiePermissions.shared.ask(for: kind)
                await run()
            }
        case .installHelperRuntime:
            Task {
                try? await DotsRuntimeInstaller.shared.installIfNeeded()
                await run()
            }
        case .checkAgain:
            Task { await run() }
        }
    }

    // MARK: - Permissions

    private func checkPermissions() async -> [Item] {
        let permissions = DottiePermissions.shared
        await permissions.refresh()
        let essentialKinds: [DottiePermissions.Kind] = [.accessibility, .screenRecording, .microphone, .inputMonitoring]
        var result = essentialKinds.map { kind -> Item in
            let status = permissions.statuses[kind] ?? .unknown
            let isAllowed = status == .allowed
            return Item(
                id: "permission-\(kind.rawValue)",
                title: kind.title,
                level: isAllowed ? .good : (kind == .inputMonitoring ? .warning : .problem),
                detail: isAllowed ? "Allowed. \(kind.reason)." : "Not allowed yet, so this won't work: \(kind.reason.lowercased()).",
                fix: isAllowed ? nil : (status == .denied ? kind.settingsURL.map { .openURL($0) } : .askPermission(kind)),
                fixLabel: isAllowed ? nil : (status == .denied ? "Open Settings" : "Allow")
            )
        }
        let optionalKinds = DottiePermissions.Kind.allCases.filter { !essentialKinds.contains($0) }
        let missingOptional = optionalKinds.filter { permissions.statuses[$0] != .allowed }
        result.append(Item(
            id: "permission-others",
            title: "Other permissions",
            level: missingOptional.isEmpty ? .good : .off,
            detail: missingOptional.isEmpty
                ? "All allowed."
                : "Optional, for extras: \(missingOptional.map(\.title).joined(separator: ", ")). Settings → Permissions has them."
        ))
        return result
    }

    private func checkAccessibilityReading() -> Item {
        guard AXIsProcessTrusted() else {
            return Item(id: "ax-read", title: "Reading apps", level: .problem,
                        detail: "Dottie can't read other apps without Accessibility.",
                        fix: .askPermission(.accessibility), fixLabel: "Allow")
        }
        // The app in front, or Finder when Dottie's own window is in front.
        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        let frontmost = NSWorkspace.shared.frontmostApplication
        let application = frontmost?.processIdentifier == ownProcessID
            ? NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
            : frontmost
        guard let application else {
            return Item(id: "ax-read", title: "Reading apps", level: .warning, detail: "No app to try it on.")
        }
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        var windowsValue: CFTypeRef?
        let readResult = AXUIElementCopyAttributeValue(applicationElement, kAXWindowsAttribute as CFString, &windowsValue)
        let name = application.localizedName ?? "the app in front"
        if readResult == .success {
            let windowCount = (windowsValue as? [AXUIElement])?.count ?? 0
            return Item(id: "ax-read", title: "Reading apps", level: .good, detail: "Read \(name) (\(windowCount) window\(windowCount == 1 ? "" : "s")).")
        }
        return Item(id: "ax-read", title: "Reading apps", level: .warning,
                    detail: "Couldn't read \(name) just now. Some apps don't share it; if this keeps happening, switch Dottie off and on in Accessibility.",
                    fix: DottiePermissions.Kind.accessibility.settingsURL.map { .openURL($0) }, fixLabel: "Open Settings")
    }

    private func checkScreenCapture() async -> Item {
        let startedAt = Date()
        guard let screenshot = await DottieDisplayCapture.captureActiveDisplay(maximumDimension: 400) else {
            return Item(id: "screen", title: "Seeing the screen", level: .problem,
                        detail: "Couldn't take a screenshot. Dottie needs Screen Recording.",
                        fix: DottiePermissions.Kind.screenRecording.settingsURL.map { .openURL($0) }, fixLabel: "Open Settings")
        }
        let milliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
        return Item(id: "screen", title: "Seeing the screen", level: .good,
                    detail: "Took a screenshot (\(screenshot.image.width)×\(screenshot.image.height)) in \(milliseconds) ms.")
    }

    // MARK: - Server and Gemini

    private static func checkWorker() async -> [Item] {
        guard ClickyWorkerConfiguration.isWorkerConfigured else {
            return [Item(id: "worker", title: "Dottie's server", level: .problem,
                         detail: "No server address yet. Add it under Connection below.")]
        }
        var result: [Item] = []
        let healthStart = Date()
        let health = await ClickyWorkerConfiguration.checkHealth(ofBaseURL: ClickyWorkerConfiguration.workerBaseURL)
        let healthMilliseconds = Int(Date().timeIntervalSince(healthStart) * 1000)
        switch health {
        case .ready:
            result.append(Item(id: "worker", title: "Dottie's server", level: healthMilliseconds < 1500 ? .good : .warning,
                               detail: "Answered in \(healthMilliseconds) ms\(healthMilliseconds < 1500 ? "." : ", which is slow. Your connection may be busy.")"))
        case .missingGeminiKey:
            return [Item(id: "worker", title: "Dottie's server", level: .problem,
                         detail: "It answers, but has no Gemini key. Add GEMINI_API_KEY to the server (see INSTALL.md).")]
        case .unreachable(let reason):
            return [Item(id: "worker", title: "Dottie's server", level: .problem,
                         detail: "Can't reach it: \(reason)", fix: .checkAgain, fixLabel: "Try again")]
        }

        async let geminiItem = checkGeminiReply()
        async let liveItem = checkLiveToken()
        result.append(await geminiItem)
        result.append(await liveItem)
        return result
    }

    private static func checkGeminiReply() async -> Item {
        let model = DottieModelPicker.shared.pick(.tiny)
        var request = URLRequest(url: ClickyWorkerConfiguration.url(forRoute: "/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        ClickyWorkerConfiguration.applyAuthenticationHeaders(to: &request)
        let body: [String: Any] = [
            "model": model,
            "contents": [["role": "user", "parts": [["text": "Reply with just the word ok."]]]],
            "generationConfig": ["maxOutputTokens": 200]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let startedAt = Date()
        do {
            let (responseData, response) = try await DottieModelPicker.shared.data(for: request, model: model)
            let seconds = Date().timeIntervalSince(startedAt)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let answer = GeminiServerSentEvents.text(from: responseData).trimmingCharacters(in: .whitespacesAndNewlines)
            guard statusCode == 200, !answer.isEmpty else {
                let isBusy = [429, 503].contains(statusCode)
                return Item(id: "gemini", title: "Gemini", level: isBusy ? .warning : .problem,
                            detail: isBusy ? "Busy or over the free limit right now (\(statusCode)). It usually clears in a minute." : "No answer (error \(statusCode)).",
                            fix: .checkAgain, fixLabel: "Try again")
            }
            return Item(id: "gemini", title: "Gemini", level: seconds < 4 ? .good : .warning,
                        detail: String(format: "Answered in %.1fs", seconds) + (seconds < 4 ? "." : ". That's slow; Gemini may be busy."))
        } catch {
            return Item(id: "gemini", title: "Gemini", level: .problem, detail: "No answer: \(error.localizedDescription)",
                        fix: .checkAgain, fixLabel: "Try again")
        }
    }

    private static func checkLiveToken() async -> Item {
        var request = URLRequest(url: ClickyWorkerConfiguration.url(forRoute: "/live-token"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        ClickyWorkerConfiguration.applyAuthenticationHeaders(to: &request)
        let startedAt = Date()
        guard let (responseData, response) = try? await URLSession.shared.data(for: request) else {
            return Item(id: "live", title: "Voice connection", level: .problem, detail: "Couldn't get a voice token from the server.",
                        fix: .checkAgain, fixLabel: "Try again")
        }
        let milliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        let payload = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        guard statusCode == 200, (payload?["token"] as? String)?.isEmpty == false else {
            return Item(id: "live", title: "Voice connection", level: .problem,
                        detail: "The server didn't give a voice token (error \(statusCode)).", fix: .checkAgain, fixLabel: "Try again")
        }
        return Item(id: "live", title: "Voice connection", level: .good, detail: "Got a voice token in \(milliseconds) ms.")
    }

    // MARK: - Microphone

    private func checkMicrophone() async -> Item {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            return Item(id: "mic", title: "Microphone sound", level: .off, detail: "Skipped: Microphone isn't allowed yet.")
        }
        guard let peak = await DottieSelfCheckProbes.microphonePeak(seconds: 1) else {
            return Item(id: "mic", title: "Microphone sound", level: .problem,
                        detail: "Couldn't open the microphone. Check the input in Sound settings.",
                        fix: URL(string: "x-apple.systempreferences:com.apple.preference.sound").map { .openURL($0) }, fixLabel: "Sound Settings")
        }
        let decibels = 20 * log10(max(peak, 0.000_001))
        if peak < 0.000_5 {
            return Item(id: "mic", title: "Microphone sound", level: .warning,
                        detail: "Heard nothing at all for a second. The microphone may be muted, or a different input is picked in Sound settings.",
                        fix: URL(string: "x-apple.systempreferences:com.apple.preference.sound").map { .openURL($0) }, fixLabel: "Sound Settings")
        }
        return Item(id: "mic", title: "Microphone sound", level: .good, detail: String(format: "Hearing sound (loudest %.0f dB).", decibels))
    }

    // MARK: - Tools

    private static func checkCommandLineTools() async -> [Item] {
        var result: [Item] = []

        if let cuaDriverURL = ClickyComputerUse.locateCuaDriverExecutable() {
            let output = await DottieSelfCheckProbes.run(cuaDriverURL, arguments: ["--version"], timeoutSeconds: 6)
            let version = output.map { $0.output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).first ?? "" } ?? ""
            result.append(output?.status == 0
                ? Item(id: "cua", title: "App control (cua-driver)", level: .good,
                       detail: "\(version.isEmpty ? "Works" : version)\(ClickyComputerUse.isCuaDriverBundled ? ", built into Dottie." : ".")")
                : Item(id: "cua", title: "App control (cua-driver)", level: .problem,
                       detail: "It's there but didn't start. Reinstalling Dottie usually fixes it."))
        } else {
            result.append(Item(id: "cua", title: "App control (cua-driver)", level: .warning,
                               detail: "Not found, so helpers can't click in apps. Reinstall Dottie from the latest release."))
        }

        result.append(DotsRuntimeInstaller.isInstalled
            ? Item(id: "runtime", title: "Helpers' engine", level: .good, detail: "Installed (Gemini CLI \(DotsRuntimeInstaller.geminiCLIVersion)).")
            : Item(id: "runtime", title: "Helpers' engine", level: .warning,
                   detail: "Not set up yet. Helpers set it up the first time they run, or tap Set up.",
                   fix: .installHelperRuntime, fixLabel: "Set up"))

        async let mausBotSearch = DottieSelfCheckProbes.findExecutable("openmausbot")
        async let claudeSearch = DottieSelfCheckProbes.findExecutable("claude")
        let foundMausBotURL = await mausBotSearch
        let foundClaudeURL = await claudeSearch
        if let mausBotURL = foundMausBotURL {
            result.append(await checkMausBot(at: mausBotURL))
        } else {
            result.append(Item(id: "openmausbot", title: "openmausbot", level: .off, detail: "Not installed (optional)."))
        }
        if let claudeURL = foundClaudeURL {
            let output = await DottieSelfCheckProbes.run(claudeURL, arguments: ["--version"], timeoutSeconds: 8)
            let version = output?.output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).first ?? ""
            result.append(Item(id: "claude", title: "claude", level: .good, detail: "Found at \(claudeURL.path)\(version.isEmpty ? "" : " (\(version.prefix(40)))")."))
        } else {
            result.append(Item(id: "claude", title: "claude", level: .off, detail: "Not installed (optional)."))
        }
        return result
    }

    private static func checkMausBot(at executableURL: URL) async -> Item {
        guard let output = await DottieSelfCheckProbes.run(executableURL, arguments: ["doctor", "--json"], timeoutSeconds: 20) else {
            return Item(id: "openmausbot", title: "openmausbot", level: .warning, detail: "Found at \(executableURL.path), but its doctor check didn't finish.")
        }
        let text = output.output
        if let jsonStart = text.firstIndex(where: { $0 == "{" || $0 == "[" }),
           let jsonObject = try? JSONSerialization.jsonObject(with: Data(text[jsonStart...].utf8)) {
            let (passed, failedNames) = doctorResults(in: jsonObject)
            if let ok = (jsonObject as? [String: Any])?["ok"] as? Bool, failedNames.isEmpty {
                return Item(id: "openmausbot", title: "openmausbot", level: ok ? .good : .warning,
                            detail: ok ? "Its doctor says everything is fine." : "Its doctor found a problem. Run `openmausbot doctor` in Terminal to see it.")
            }
            if failedNames.isEmpty {
                return Item(id: "openmausbot", title: "openmausbot", level: .good, detail: "Its doctor passed \(passed) check\(passed == 1 ? "" : "s").")
            }
            return Item(id: "openmausbot", title: "openmausbot", level: .warning,
                        detail: "Its doctor found problems with: \(failedNames.prefix(4).joined(separator: ", ")).")
        }
        let firstLine = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).first ?? ""
        return Item(id: "openmausbot", title: "openmausbot", level: output.status == 0 ? .good : .warning,
                    detail: output.status == 0 ? "Its doctor ran fine." : "Its doctor said: \(firstLine.prefix(120))")
    }

    /// Counts passed checks and names failed ones in a doctor report,
    /// whatever its exact shape: entries with "ok", "passed" or "status".
    private static func doctorResults(in jsonObject: Any) -> (passed: Int, failedNames: [String]) {
        var passed = 0
        var failedNames: [String] = []
        func visit(_ value: Any, name: String?) {
            if let dictionary = value as? [String: Any] {
                let entryName = (dictionary["name"] as? String) ?? (dictionary["check"] as? String) ?? (dictionary["id"] as? String) ?? name
                var verdict: Bool?
                if let ok = (dictionary["ok"] as? Bool) ?? (dictionary["passed"] as? Bool) { verdict = ok }
                if let status = (dictionary["status"] as? String)?.lowercased() {
                    if ["ok", "pass", "passed", "good", "success"].contains(status) { verdict = true }
                    if ["fail", "failed", "error", "missing", "bad"].contains(status) { verdict = false }
                }
                if let verdict, entryName != nil {
                    if verdict { passed += 1 } else { failedNames.append(entryName ?? "something") }
                    return
                }
                for (key, child) in dictionary where !(child is String) && !(child is NSNumber) {
                    visit(child, name: key)
                }
            } else if let array = value as? [Any] {
                for child in array { visit(child, name: nil) }
            }
        }
        visit(jsonObject, name: nil)
        return (passed, failedNames)
    }

    private func checkTelegram() -> Item {
        guard let phoneBridge else {
            return Item(id: "telegram", title: "Phone (Telegram)", level: .off, detail: "Not set up (optional).")
        }
        if phoneBridge.isConnected {
            return phoneBridge.pairedChatID != nil
                ? Item(id: "telegram", title: "Phone (Telegram)", level: .good, detail: "Connected\(phoneBridge.botUsername.map { " as @\($0)" } ?? "") and paired with your phone.")
                : Item(id: "telegram", title: "Phone (Telegram)", level: .warning,
                       detail: "Connected, but no phone is paired. Send the pairing code from Home → Phone to the bot.")
        }
        if !phoneBridge.statusText.isEmpty || phoneBridge.pairedChatID != nil {
            return Item(id: "telegram", title: "Phone (Telegram)", level: .problem,
                        detail: "Set up, but not connected right now. \(phoneBridge.statusText)")
        }
        return Item(id: "telegram", title: "Phone (Telegram)", level: .off, detail: "Not set up (optional).")
    }

    private func checkOnDeviceModel() -> Item {
        if DottieOnDeviceModel.isAvailable {
            return Item(id: "apple-model", title: "Apple's on-device model", level: .good,
                        detail: "Ready. Dottie uses it for quick sorting and simple answers, with no internet.")
        }
        let reason = DottieOnDeviceModel.unavailableReason ?? "Not available."
        let canTurnOn = reason.contains("Apple Intelligence is off")
        return Item(id: "apple-model", title: "Apple's on-device model", level: .off,
                    detail: "\(reason) Optional: Dottie works without it, a little slower.",
                    fix: canTurnOn ? URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension").map { .openURL($0) } : nil,
                    fixLabel: canTurnOn ? "Open Settings" : nil)
    }
}

// MARK: - Probes that run off the main thread

enum DottieSelfCheckProbes {
    /// The loudest sound level (0-1) the default input hears in `seconds`,
    /// or nil when the microphone can't be opened.
    static func microphonePeak(seconds: Double) async -> Float? {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return nil }
        let peakLevel = PeakLevel()
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sumOfSquares: Float = 0
            for index in 0..<Int(buffer.frameLength) {
                sumOfSquares += samples[index] * samples[index]
            }
            peakLevel.note((sumOfSquares / Float(buffer.frameLength)).squareRoot())
        }
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            return nil
        }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        inputNode.removeTap(onBus: 0)
        engine.stop()
        return peakLevel.value
    }

    private final class PeakLevel: @unchecked Sendable {
        private let lock = NSLock()
        private var peak: Float = 0
        func note(_ level: Float) {
            lock.lock()
            peak = max(peak, level)
            lock.unlock()
        }
        var value: Float {
            lock.lock()
            defer { lock.unlock() }
            return peak
        }
    }

    /// Folders where command-line tools usually live; a Mac app doesn't get
    /// the user's shell PATH.
    static var toolFolders: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin",
            "\(home)/.claude/local", "\(home)/.volta/bin", "\(home)/.cargo/bin", "/usr/bin", "/bin"
        ]
    }

    /// Finds a command-line tool by name: the usual folders first, then the
    /// user's login shell.
    static func findExecutable(_ name: String) async -> URL? {
        for folder in toolFolders {
            let path = (folder as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        guard let output = await run(URL(fileURLWithPath: "/bin/zsh"), arguments: ["-lic", "command -v \(name)"], timeoutSeconds: 5) else {
            return nil
        }
        let path = output.output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") && $0.hasSuffix("/\(name)") }
        guard let path, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Runs a program and returns its exit status and output, or nil when
    /// it can't start or doesn't finish in time.
    static func run(_ executableURL: URL, arguments: [String], timeoutSeconds: Double) async -> (status: Int32, output: String)? {
        await withCheckedContinuation { continuation in
            let answer = AnswerOnce(continuation)
            // A program whose children keep its output open never ends, so
            // the answer comes from a timer too.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds + 2) { answer.give(nil) }
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executableURL
                process.arguments = arguments
                var environment = ProcessInfo.processInfo.environment
                let folders = [executableURL.deletingLastPathComponent().path] + toolFolders
                environment["PATH"] = (folders + [environment["PATH"] ?? ""]).joined(separator: ":")
                process.environment = environment
                let outputPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = outputPipe
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    answer.give(nil)
                    return
                }
                let stopper = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: stopper)
                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                stopper.cancel()
                answer.give((process.terminationStatus, String(decoding: outputData.prefix(200_000), as: UTF8.self)))
            }
        }
    }

    /// Resumes a continuation once, whichever answer comes first.
    private final class AnswerOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<(status: Int32, output: String)?, Never>?

        init(_ continuation: CheckedContinuation<(status: Int32, output: String)?, Never>) {
            self.continuation = continuation
        }

        func give(_ value: (status: Int32, output: String)?) {
            lock.lock()
            let pendingContinuation = continuation
            continuation = nil
            lock.unlock()
            pendingContinuation?.resume(returning: value)
        }
    }
}
