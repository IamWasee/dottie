//
//  DottieClaudeAccount.swift
//  leanring-buddy
//
//  Which Claude account the helpers use, and signing in to a different one.
//
//  Who's signed in comes from Claude Code itself: `claude auth status`
//  prints one JSON document (checked against Claude Code 2.1.303):
//    loggedIn          true or false (the exit code is 1 when signed out)
//    authMethod        "claude.ai" for a Claude plan login, else
//                      "oauth_token", "api_key", "third_party", "none", …
//    email, orgName    the account, only for "claude.ai" logins
//    subscriptionType  "pro", "max", "team", "enterprise", or null
//
//  Signing in runs `claude auth login --claudeai` right here, no Terminal.
//  Claude Code opens the sign-in page with whatever $BROWSER names, so
//  Dottie points $BROWSER at a tiny script that writes the link to a file
//  instead of opening it. The user then opens that link where they like:
//  a private window shows claude.ai's account picker, where their normal
//  browser would quietly reuse whoever is signed in to claude.ai. The page
//  sends the browser back to Claude Code on localhost, which finishes by
//  itself. When the link can't be caught that way, Dottie shows the link
//  Claude Code prints instead; that page ends with a code the user pastes
//  into Dottie, which hands it to Claude Code on its standard input.
//
//  "Use a different account" runs `claude auth logout` first. Helpers use
//  the free Gemini backup while Claude is signed out, as they always do.
//

import AppKit
import Combine
import Foundation

// MARK: - Who's signed in

/// The Claude account Claude Code is signed in to, as `claude auth status` reports it.
struct DottieClaudeAccount: Equatable {
    let email: String?
    let organizationName: String?
    let subscriptionType: String?
    let authMethod: String?

    /// Reads `claude auth status --json`. Nil when it says it's signed out.
    init?(statusObject: [String: Any]) {
        guard statusObject["loggedIn"] as? Bool == true else { return nil }
        func nonEmptyString(_ key: String) -> String? {
            guard let value = statusObject[key] as? String else { return nil }
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedValue.isEmpty ? nil : trimmedValue
        }
        email = nonEmptyString("email")
        organizationName = nonEmptyString("orgName")
        subscriptionType = nonEmptyString("subscriptionType")
        authMethod = nonEmptyString("authMethod")
    }

    /// "Claude Max", "Claude Pro", … or nil when Claude Code didn't say.
    var planName: String? {
        guard let subscriptionType else { return nil }
        switch subscriptionType.lowercased() {
        case "max": return "Claude Max"
        case "pro": return "Claude Pro"
        case "team": return "Claude Team"
        case "enterprise": return "Claude Enterprise"
        case "free": return "Claude Free"
        default: return "Claude \(subscriptionType.capitalized)"
        }
    }

    /// The organization, unless it's just the personal one Claude makes for
    /// every account ("you@example.com's Organization").
    var meaningfulOrganizationName: String? {
        guard let organizationName else { return nil }
        let lowercasedName = organizationName.lowercased()
        if lowercasedName.hasSuffix("'s organization") || lowercasedName.hasSuffix("’s organization") {
            return nil
        }
        if let email, lowercasedName.contains(email.lowercased()) {
            return nil
        }
        return organizationName
    }

    /// "you@example.com · Claude Max · Acme", or a plain "Signed in" when
    /// Claude Code doesn't name the account (an API key or a token).
    var summary: String {
        let parts = [email, planName, meaningfulOrganizationName].compactMap { $0 }
        if !parts.isEmpty {
            return parts.joined(separator: " · ")
        }
        switch authMethod {
        case "api_key", "api_key_helper": return "Signed in with an API key"
        default: return "Signed in"
        }
    }
}

// MARK: - Signing in from Dottie

/// Runs Claude Code's sign-in inside Dottie and shows its link, so the user
/// can pick any Claude account (see the top of this file).
@MainActor
final class DottieClaudeSignIn: ObservableObject {
    static let shared = DottieClaudeSignIn()

    enum Phase: Equatable {
        case idle
        case signingOut
        case starting
        /// The link is ready; Claude Code waits for the browser.
        case waitingForBrowser
        case finishing
        case finished(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// The sign-in page to open.
    @Published private(set) var signInLink: URL?
    /// True for the link Claude Code prints: its page ends with a code to
    /// paste back into Dottie.
    @Published private(set) var linkNeedsCode = false
    /// True while switching to a different account (rather than a first sign-in).
    @Published private(set) var isSwitchingAccount = false
    /// A short note under the buttons ("Link copied", a browser that didn't open).
    @Published private(set) var noteText: String?

    private var loginProcess: Process?
    private var loginInputPipe: Pipe?
    private var flowTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var wasCancelled = false

    /// How long Claude Code waits for the browser before Dottie gives up.
    private static let signInTimeout: TimeInterval = 10 * 60

    private init() {}

    /// True from the moment a sign-in starts until it ends.
    var isInProgress: Bool {
        switch phase {
        case .signingOut, .starting, .waitingForBrowser, .finishing: return true
        case .idle, .finished, .failed: return false
        }
    }

    /// What the panel says while it works.
    var progressText: String? {
        switch phase {
        case .signingOut: return "Signing Claude out…"
        case .starting: return "Getting the sign-in link…"
        case .finishing: return "Almost done…"
        default: return nil
        }
    }

    // MARK: Starting and stopping

    /// Starts a sign-in. `switchingAccount` signs the current account out
    /// first and leaves opening the link to the user (a private window lets
    /// them pick the account); a first sign-in opens their browser right away.
    func start(switchingAccount: Bool) {
        guard !isInProgress else { return }
        cancelRunningLogin()
        wasCancelled = false
        isSwitchingAccount = switchingAccount
        signInLink = nil
        linkNeedsCode = false
        noteText = nil
        phase = switchingAccount ? .signingOut : .starting
        flowTask = Task { await self.runSignIn(switchingAccount: switchingAccount) }
    }

    /// "Cancel" in the panel.
    func cancel() {
        wasCancelled = true
        flowTask?.cancel()
        flowTask = nil
        cancelRunningLogin()
        phase = .idle
        signInLink = nil
        noteText = nil
        Task { await DottieMausBot.shared.refreshClaudeState() }
    }

    /// Hides a finished or failed result.
    func dismissResult() {
        guard !isInProgress else { return }
        phase = .idle
        signInLink = nil
        noteText = nil
    }

    private func cancelRunningLogin() {
        timeoutTask?.cancel()
        timeoutTask = nil
        if let loginProcess, loginProcess.isRunning {
            loginProcess.terminate()
        }
        loginProcess = nil
        loginInputPipe = nil
    }

    private func runSignIn(switchingAccount: Bool) async {
        let claudeURL = await Task.detached(priority: .userInitiated) {
            DottieMausBotLocator.locateClaudeCLI()
        }.value
        guard let claudeURL else {
            phase = .failed("Claude Code isn't installed yet. Tap Set up first.")
            return
        }

        if switchingAccount {
            _ = await DottieMausBotProcessRunner.run(
                executableURL: claudeURL,
                arguments: ["auth", "logout"],
                environment: Self.claudeEnvironment(browserScriptPath: nil),
                timeout: 30
            )
            if Task.isCancelled { return }
            // Helpers see "not signed in" from here and use the Gemini backup.
            await DottieMausBot.shared.refreshClaudeState()
            if Task.isCancelled { return }
            phase = .starting
        }

        guard launchLogin(claudeURL: claudeURL) else {
            // Couldn't run it here: fall back to signing in through Terminal.
            phase = .idle
            DottieMausBot.shared.openClaudeSignInInTerminal()
            return
        }
        await waitForSignInLink()
        if Task.isCancelled || !isInProgress { return }
        guard signInLink != nil else {
            failIfStillRunning("Claude Code didn't give a sign-in link. Try again.")
            return
        }
        phase = .waitingForBrowser
        if !switchingAccount {
            openLinkInUsersBrowser()
        }
        timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.signInTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.failIfStillRunning("The sign-in timed out. Try again when you're ready.")
        }
    }

    // MARK: Claude Code's login process

    private let linkCatcher = DottieClaudeLoginOutput()

    private func launchLogin(claudeURL: URL) -> Bool {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: Self.caughtLinkFileURL)
        guard writeLinkCatcherScript() else { return false }
        linkCatcher.reset()

        let process = Process()
        process.executableURL = claudeURL
        process.arguments = ["auth", "login", "--claudeai"]
        process.environment = Self.claudeEnvironment(browserScriptPath: Self.linkCatcherScriptURL.path)
        process.currentDirectoryURL = fileManager.homeDirectoryForCurrentUser
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let linkCatcher = self.linkCatcher
        outputPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            let availableData = fileHandle.availableData
            guard !availableData.isEmpty else { return }
            linkCatcher.appendStandardOutput(availableData)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            let availableData = fileHandle.availableData
            guard !availableData.isEmpty else { return }
            linkCatcher.appendStandardError(availableData)
        }
        process.terminationHandler = { finishedProcess in
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            let exitCode = finishedProcess.terminationStatus
            Task { @MainActor in
                DottieClaudeSignIn.shared.loginEnded(process: finishedProcess, exitCode: exitCode)
            }
        }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            return false
        }
        loginProcess = process
        loginInputPipe = inputPipe
        return true
    }

    /// Waits for the link: the one $BROWSER caught (finishes by itself), or
    /// after a moment the one Claude Code printed (ends with a code).
    private func waitForSignInLink() async {
        var stepsSincePrintedLink = 0
        for _ in 0..<120 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled || loginProcess == nil { return }
            if let caughtLink = Self.readCaughtLink() {
                signInLink = caughtLink
                linkNeedsCode = false
                return
            }
            if linkCatcher.printedLink != nil {
                stepsSincePrintedLink += 1
                // Claude Code runs $BROWSER right after printing; give it ~3 s.
                if stepsSincePrintedLink >= 12, let printedLink = linkCatcher.printedLink {
                    signInLink = printedLink
                    linkNeedsCode = true
                    return
                }
            }
        }
        if let printedLink = linkCatcher.printedLink {
            signInLink = printedLink
            linkNeedsCode = true
        }
    }

    private func loginEnded(process: Process, exitCode: Int32) {
        guard process === loginProcess else { return }
        loginProcess = nil
        loginInputPipe = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        try? FileManager.default.removeItem(at: Self.caughtLinkFileURL)
        if wasCancelled { return }
        if exitCode == 0 {
            phase = .finishing
            Task {
                await DottieMausBot.shared.claudeSignInFinished()
                let account = DottieMausBot.shared.claudeAccount
                if let email = account?.email {
                    self.phase = .finished("Signed in as \(email). Helpers use this account now.")
                } else {
                    self.phase = .finished("Signed in. Helpers use your Claude plan now.")
                }
                self.signInLink = nil
            }
        } else {
            let errorText = linkCatcher.errorTail
            phase = .failed(errorText.isEmpty
                ? "The sign-in didn't finish. Try again."
                : "The sign-in didn't finish: \(DottieMausBotRuntime.singleLine(errorText, maximumLength: 200))")
            signInLink = nil
            Task { await DottieMausBot.shared.refreshClaudeState() }
        }
    }

    private func failIfStillRunning(_ message: String) {
        guard isInProgress else { return }
        wasCancelled = true
        cancelRunningLogin()
        phase = .failed(message)
        signInLink = nil
    }

    // MARK: What the panel's buttons do

    func copyLink() {
        guard let signInLink else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(signInLink.absoluteString, forType: .string)
        noteText = "Link copied. Paste it into a private window."
    }

    func openLinkInUsersBrowser() {
        guard let signInLink else { return }
        Task { _ = await DottieBrowser.openInUsersBrowser(signInLink) }
    }

    func openLinkInPrivateWindow(browser: DottiePrivateBrowser?) {
        guard let signInLink else { return }
        guard let browser = browser ?? DottiePrivateBrowser.preferred else {
            copyLink()
            noteText = "No browser found. The link is copied: paste it into a private window."
            return
        }
        noteText = nil
        Task {
            let didOpen = await browser.openPrivateWindow(with: signInLink)
            if !didOpen {
                self.copyLink()
                self.noteText = "\(browser.name) didn't open a private window. The link is copied: open one (⇧⌘N) and paste it."
            }
        }
    }

    /// The code the sign-in page shows at the end of Claude Code's own link.
    func submitCode(_ code: String) {
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty, let loginInputPipe else { return }
        guard trimmedCode.contains("#") else {
            noteText = "That code looks cut short. Copy the whole code from the page."
            return
        }
        loginInputPipe.fileHandleForWriting.write(Data((trimmedCode + "\n").utf8))
        noteText = "Checking the code…"
    }

    // MARK: Files and environment

    /// In the temporary folder: its path has no spaces, so it works however
    /// Claude Code runs $BROWSER.
    private static var linkCatcherScriptURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("dottie-claude-sign-in-link.sh", isDirectory: false)
    }

    private static var caughtLinkFileURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("dottie-claude-sign-in-link.txt", isDirectory: false)
    }

    private func writeLinkCatcherScript() -> Bool {
        let escapedLinkFilePath = Self.caughtLinkFileURL.path.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        #!/bin/sh
        # Written by Dottie: hands Claude Code's sign-in link to Dottie instead of opening a browser.
        printf '%s\\n' "$1" > '\(escapedLinkFilePath)'

        """
        do {
            try script.write(to: Self.linkCatcherScriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Self.linkCatcherScriptURL.path)
            return true
        } catch {
            return false
        }
    }

    private static func readCaughtLink() -> URL? {
        guard let fileContents = try? String(contentsOf: caughtLinkFileURL, encoding: .utf8) else { return nil }
        let linkText = fileContents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard linkText.hasPrefix("https://"), let link = URL(string: linkText) else { return nil }
        return link
    }

    /// MausBot's environment without anything that would sign Claude Code
    /// in some other way (the same list the Terminal sign-in unsets).
    static func claudeEnvironment(browserScriptPath: String?) -> [String: String] {
        var environment = DottieMausBotLocator.childEnvironment()
        for key in ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CONFIG_DIR"] {
            environment.removeValue(forKey: key)
        }
        if let browserScriptPath {
            environment["BROWSER"] = browserScriptPath
        } else {
            environment.removeValue(forKey: "BROWSER")
        }
        return environment
    }
}

/// Collects what `claude auth login` prints, from the pipes' background queues.
private final class DottieClaudeLoginOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var outputText = ""
    private var errorText = ""

    func reset() {
        lock.lock()
        outputText = ""
        errorText = ""
        lock.unlock()
    }

    func appendStandardOutput(_ newData: Data) {
        lock.lock()
        outputText += String(decoding: newData, as: UTF8.self)
        if outputText.count > 20_000 { outputText = String(outputText.suffix(20_000)) }
        lock.unlock()
    }

    func appendStandardError(_ newData: Data) {
        lock.lock()
        errorText += String(decoding: newData, as: UTF8.self)
        if errorText.count > 2_000 { errorText = String(errorText.suffix(2_000)) }
        lock.unlock()
    }

    var errorTail: String {
        lock.lock()
        defer { lock.unlock() }
        return errorText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The link after "If the browser didn't open, visit:". Claude Code may
    /// wrap it in a terminal hyperlink, so it ends at the first space or
    /// control character.
    var printedLink: URL? {
        lock.lock()
        let text = outputText
        lock.unlock()
        guard let markerRange = text.range(of: "visit:") ?? text.range(of: "https://") else { return nil }
        guard let linkStart = text.range(of: "https://", range: markerRange.lowerBound..<text.endIndex) else { return nil }
        var linkText = ""
        for character in text[linkStart.lowerBound...] {
            if character.isWhitespace || character.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
                break
            }
            linkText.append(character)
        }
        guard linkText.count > "https://".count else { return nil }
        return URL(string: linkText)
    }
}

// MARK: - Private windows

/// A browser that can open a private window, so claude.ai asks which
/// account to use instead of reusing the one the browser is signed in to.
struct DottiePrivateBrowser: Identifiable, Hashable {
    enum Method: Hashable {
        /// `open -na <app> --args <flags> <url>` (Chrome-style browsers).
        case launchArguments([String])
        /// Firefox's own binary, which hands the window to the running Firefox.
        case firefoxBinary
        /// Arc's AppleScript (`make new window with properties {incognito:true}`).
        case arcScript
        /// Safari: ⇧⌘N, then the link pasted into the new window.
        case safariKeystrokes
    }

    let bundleIdentifier: String
    let name: String
    let method: Method

    var id: String { bundleIdentifier }

    private static let supportedBrowsers: [DottiePrivateBrowser] = [
        DottiePrivateBrowser(bundleIdentifier: "com.apple.Safari", name: "Safari", method: .safariKeystrokes),
        DottiePrivateBrowser(bundleIdentifier: "com.google.Chrome", name: "Chrome", method: .launchArguments(["--incognito"])),
        DottiePrivateBrowser(bundleIdentifier: "company.thebrowser.Browser", name: "Arc", method: .arcScript),
        DottiePrivateBrowser(bundleIdentifier: "com.operasoftware.OperaGX", name: "Opera GX", method: .launchArguments(["--private"])),
        DottiePrivateBrowser(bundleIdentifier: "com.operasoftware.Opera", name: "Opera", method: .launchArguments(["--private"])),
        DottiePrivateBrowser(bundleIdentifier: "com.brave.Browser", name: "Brave", method: .launchArguments(["--incognito"])),
        DottiePrivateBrowser(bundleIdentifier: "com.microsoft.edgemac", name: "Edge", method: .launchArguments(["--inprivate"])),
        DottiePrivateBrowser(bundleIdentifier: "com.vivaldi.Vivaldi", name: "Vivaldi", method: .launchArguments(["--incognito"])),
        DottiePrivateBrowser(bundleIdentifier: "org.mozilla.firefox", name: "Firefox", method: .firefoxBinary)
    ]

    /// The supported browsers on this Mac.
    static var installed: [DottiePrivateBrowser] {
        supportedBrowsers.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleIdentifier) != nil }
    }

    /// The browser the user uses when it's supported, else the first one installed.
    static var preferred: DottiePrivateBrowser? {
        let installedBrowsers = installed
        if let usersBrowserID = DottieBrowser.usersBrowserBundleIdentifier,
           let usersBrowser = installedBrowsers.first(where: { $0.bundleIdentifier == usersBrowserID }) {
            return usersBrowser
        }
        return installedBrowsers.first
    }

    @MainActor
    func openPrivateWindow(with link: URL) async -> Bool {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return false }
        let linkText = link.absoluteString
        switch method {
        case .launchArguments(let flags):
            let result = await DottieMacActions.runProcess(
                "/usr/bin/open",
                arguments: ["-n", "-a", applicationURL.path, "--args"] + flags + [linkText],
                timeout: 15
            )
            return result.exitCode == 0
        case .firefoxBinary:
            let firefoxBinaryPath = applicationURL.appendingPathComponent("Contents/MacOS/firefox").path
            guard FileManager.default.isExecutableFile(atPath: firefoxBinaryPath) else { return false }
            let firefoxProcess = Process()
            firefoxProcess.executableURL = URL(fileURLWithPath: firefoxBinaryPath)
            firefoxProcess.arguments = ["--private-window", linkText]
            firefoxProcess.standardInput = FileHandle.nullDevice
            firefoxProcess.standardOutput = FileHandle.nullDevice
            firefoxProcess.standardError = FileHandle.nullDevice
            do {
                try firefoxProcess.run()
                return true
            } catch {
                return false
            }
        case .arcScript:
            let script = """
            tell application "Arc"
                make new window with properties {incognito:true}
                activate
                tell front window to make new tab with properties {URL:\(Self.appleScriptString(linkText))}
            end tell
            """
            let result = await DottieMacActions.runProcess("/usr/bin/osascript", arguments: ["-e", script], timeout: 15)
            return result.exitCode == 0
        case .safariKeystrokes:
            // Safari has no private-window flag or script command, so: a new
            // private window, then the link pasted into its address bar.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(linkText, forType: .string)
            let script = """
            tell application "Safari" to activate
            delay 0.4
            tell application "System Events"
                keystroke "n" using {command down, shift down}
                delay 0.6
                keystroke "v" using {command down}
                delay 0.1
                key code 36
            end tell
            """
            let result = await DottieMacActions.runProcess("/usr/bin/osascript", arguments: ["-e", script], timeout: 15)
            return result.exitCode == 0
        }
    }

    private static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
