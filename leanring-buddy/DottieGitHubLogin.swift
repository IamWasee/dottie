//
//  DottieGitHubLogin.swift
//  leanring-buddy
//
//  GitHub for Home → Tools without copying a token by hand: "Sign in with
//  GitHub" gets the GitHub CLI if needed, signs in through the browser
//  with a one-time code, and uses gh's token (DottieGitHubSignIn).
//  Also moves an old "GitHub" sign-in connector (mcp-remote to GitHub's
//  hosted server, which always failed with a 404 because GitHub doesn't
//  let apps register for a browser sign-in) over to the token setup.
//

import AppKit
import CryptoKit
import Foundation

enum DottieGitHubLogin {
    /// The GitHub CLI's token, or nil when gh isn't installed or signed in.
    static func cliToken() async -> String? {
        guard let ghPath = DottieCommandLocator.locate("gh") else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ghPath)
            process.arguments = ["auth", "token"]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = DottieCommandLocator.searchPATH
            process.environment = environment
            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = Pipe()
            do {
                try process.run()
            } catch {
                return nil
            }
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let token = String(decoding: outputData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return token.isEmpty ? nil : token
        }.value
    }

    /// Whether a server is GitHub's hosted one, so `use_app_tool` can add a
    /// hint to its 404s.
    static func isGitHubServer(_ config: DottieMCPServerConfig?) -> Bool {
        guard let config else { return false }
        let addresses = [config.url ?? ""] + config.args
        return addresses.contains { $0.contains("api.githubcopilot.com") }
    }

    /// What to tell the model when GitHub answered 404: GitHub says 404
    /// (not 403) for a private repository the token can't see, and for a
    /// guessed owner name that doesn't exist.
    static let notFoundHint = """
    GitHub says 404 both for a name that doesn't exist and for a private repository this token can't see. Don't guess the owner: call get_me for the user's login (and list their repositories if needed), then try again with the exact owner/repo. If it still says 404, tell the user to open Home → Tools → GitHub and press Sign in with GitHub with the account that owns that repository (or give their token access to it).
    """

    /// One line about the account GitHub's get_me says the token is for:
    /// its login (so owner/repo can be built from it), or that the sign-in
    /// itself is broken and the user has to sign in again.
    static func signedInAccountNote(fromGetMeResult getMeResult: String) -> String {
        if let loginRange = getMeResult.range(of: #""login"\s*:\s*"([^"]+)""#, options: .regularExpression) {
            let loginField = String(getMeResult[loginRange])
            let login = loginField.split(separator: "\"").dropFirst(2).first.map(String.init) ?? loginField
            return "the GitHub token belongs to \(login). use \(login) as the owner for their own repositories (exact repo name from search_repositories if unsure). if it's still 404 with \(login)/<repo>, the repository belongs to another account the token can't see: tell the user to sign in again with Sign in with GitHub in Home → Tools, with the account that owns it."
        }
        return "get_me failed too, so the GitHub sign-in itself isn't working (\(getMeResult.prefix(160))). tell the user in one sentence to open Home → Tools → GitHub and press Sign in with GitHub; don't keep retrying."
    }
}

/// "Sign in with GitHub" in Home → Tools, so nobody makes a token by hand:
/// 1. Gets the GitHub CLI (gh) when the Mac has none: Homebrew when it's
///    there, otherwise the official release from github.com/cli/cli,
///    checked against its SHA-256 list, into ~/.local/bin.
/// 2. Runs `gh auth login --web`, which prints a one-time code. Dottie
///    copies the code, opens github.com/login/device, and the user pastes
///    it and clicks Authorize.
/// 3. Takes gh's token and adds the GitHub app with it (Keychain).
/// Already signed in to gh? Then it's just step 3.
@MainActor
final class DottieGitHubSignIn: ObservableObject {
    static let shared = DottieGitHubSignIn()

    enum Phase: Equatable {
        case idle
        case working(String)
        /// The one-time code to paste on github.com/login/device.
        case waitingForBrowser(code: String)
        case connected
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    static let deviceLoginURL = URL(string: "https://github.com/login/device")!

    var isBusy: Bool {
        switch phase {
        case .working, .waitingForBrowser: return true
        default: return false
        }
    }

    private init() {}

    /// Signs in and adds GitHub under `serverName` (the "github" preset's
    /// id for a new one, or the name of one already added).
    /// `forceNewLogin` signs in again even when gh already has an account
    /// (to switch to the account that owns a repository).
    func signIn(store: DottieToolsStore, serverName: String = "github", forceNewLogin: Bool = false) async {
        guard !isBusy else { return }
        guard let gitHubPreset = DottieMCPPresets.preset(withID: "github") else { return }

        if !forceNewLogin, let existingToken = await DottieGitHubLogin.cliToken() {
            finish(store: store, preset: gitHubPreset, serverName: serverName, token: existingToken)
            return
        }

        phase = .working("Getting GitHub's sign-in tool…")
        guard let ghPath = await installedGitHubCLIPath() else {
            phase = .failed("Couldn't get GitHub's sign-in tool. Check the internet connection and try again, or use a token instead.")
            return
        }

        phase = .working("Opening GitHub…")
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = DottieCommandLocator.searchPATH
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        // gh opens the browser itself only when it can ask "press Enter";
        // Dottie opens the page and copies the code instead.
        environment["GH_BROWSER"] = "/usr/bin/true"
        environment["BROWSER"] = "/usr/bin/true"
        let result = await DottieProcessRunner.run(
            ghPath,
            arguments: ["auth", "login", "--hostname", "github.com", "--git-protocol", "https", "--web", "--scopes", "repo,read:org,workflow"],
            environment: environment,
            timeout: 900
        ) { line in
            guard let code = Self.oneTimeCode(in: line) else { return }
            Task { @MainActor in
                DottieGitHubSignIn.shared.showCode(code)
            }
        }

        guard result.exitCode == 0, let newToken = await DottieGitHubLogin.cliToken() else {
            let reason = DottieMCPStdioTransport.lastMeaningfulLine(of: result.errorOutput.isEmpty ? result.output : result.errorOutput)
            phase = .failed("GitHub sign-in didn't finish. \(reason)")
            return
        }
        finish(store: store, preset: gitHubPreset, serverName: serverName, token: newToken)
    }

    func reset() {
        if !isBusy { phase = .idle }
    }

    private func showCode(_ code: String) {
        guard isBusy else { return }
        phase = .waitingForBrowser(code: code)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        NSWorkspace.shared.open(Self.deviceLoginURL)
    }

    private func finish(store: DottieToolsStore, preset: DottieMCPPreset, serverName: String, token: String) {
        if serverName == preset.id || store.config(for: serverName) == nil {
            if let problem = store.addPreset(preset, values: ["GITHUB_TOKEN": token], folders: [:]) {
                phase = .failed(problem)
                return
            }
        } else {
            store.setKey(token, name: "GITHUB_TOKEN", for: serverName)
        }
        phase = .connected
    }

    /// gh prints "! First copy your one-time code: 1A2B-3C4D".
    nonisolated static func oneTimeCode(in line: String) -> String? {
        guard line.localizedCaseInsensitiveContains("code"),
              let range = line.range(of: "[A-Z0-9]{4}-[A-Z0-9]{4}", options: .regularExpression) else { return nil }
        return String(line[range])
    }

    // MARK: Getting gh

    private func installedGitHubCLIPath() async -> String? {
        if let ghPath = DottieCommandLocator.locate("gh") { return ghPath }
        if DottieCommandLocator.locate("brew") != nil, let ghTool = DottieCLICatalog.tool(withID: "gh") {
            phase = .working("Installing GitHub's sign-in tool with Homebrew…")
            await DottieCLIToolsManager.shared.install(ghTool)
            if let ghPath = DottieCommandLocator.locate("gh") { return ghPath }
        }
        phase = .working("Downloading GitHub's sign-in tool…")
        let downloadedPath = await Self.downloadOfficialGitHubCLI()
        await DottieCommandLocator.refresh()
        return downloadedPath ?? DottieCommandLocator.locate("gh")
    }

    /// The newest gh release for macOS from GitHub itself, checked against
    /// the release's own checksums, put in ~/.local/bin (which Dottie and
    /// most shells already look in). No password needed.
    nonisolated private static func downloadOfficialGitHubCLI() async -> String? {
        guard let releaseURL = URL(string: "https://api.github.com/repos/cli/cli/releases/latest"),
              let (releaseData, _) = try? await URLSession.shared.data(from: releaseURL),
              let release = try? JSONSerialization.jsonObject(with: releaseData) as? [String: Any],
              let assets = release["assets"] as? [[String: Any]] else { return nil }
        func assetURL(named matches: (String) -> Bool) -> (name: String, url: URL)? {
            for asset in assets {
                guard let name = asset["name"] as? String, matches(name),
                      let urlText = asset["browser_download_url"] as? String, let url = URL(string: urlText) else { continue }
                return (name, url)
            }
            return nil
        }
        #if arch(arm64)
        let architectureSuffix = "_macOS_arm64.zip"
        #else
        let architectureSuffix = "_macOS_amd64.zip"
        #endif
        guard let archive = assetURL(named: { $0.hasSuffix("_macOS_universal.zip") }) ?? assetURL(named: { $0.hasSuffix(architectureSuffix) }),
              let checksums = assetURL(named: { $0.hasSuffix("_checksums.txt") }),
              let (checksumData, _) = try? await URLSession.shared.data(from: checksums.url),
              let (archiveFileURL, _) = try? await URLSession.shared.download(from: archive.url),
              let archiveData = try? Data(contentsOf: archiveFileURL) else { return nil }

        let expectedLine = String(decoding: checksumData, as: UTF8.self)
            .split(separator: "\n")
            .first { $0.hasSuffix(archive.name) }
        let actualHash = SHA256.hash(data: archiveData).map { String(format: "%02x", $0) }.joined()
        guard let expectedLine, expectedLine.hasPrefix(actualHash) else {
            print("⚠️ gh download didn't match its checksum; not installing it")
            return nil
        }

        let workFolder = FileManager.default.temporaryDirectory.appendingPathComponent("dottie-gh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workFolder) }
        try? FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
        let zipURL = workFolder.appendingPathComponent(archive.name)
        try? archiveData.write(to: zipURL)
        let unzip = await DottieProcessRunner.run("/usr/bin/ditto", arguments: ["-x", "-k", zipURL.path, workFolder.path], timeout: 120)
        guard unzip.exitCode == 0,
              let enumerator = FileManager.default.enumerator(at: workFolder, includingPropertiesForKeys: nil) else { return nil }
        var unpackedBinaryURL: URL?
        for case let fileURL as URL in enumerator where fileURL.lastPathComponent == "gh" && fileURL.deletingLastPathComponent().lastPathComponent == "bin" {
            unpackedBinaryURL = fileURL
        }
        guard let unpackedBinaryURL else { return nil }

        let binFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        let installedURL = binFolder.appendingPathComponent("gh")
        try? FileManager.default.createDirectory(at: binFolder, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: installedURL)
        do {
            try FileManager.default.copyItem(at: unpackedBinaryURL, to: installedURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedURL.path)
        } catch {
            return nil
        }
        // Downloaded files are quarantined; this one was checked above.
        _ = await DottieProcessRunner.run("/usr/bin/xattr", arguments: ["-d", "com.apple.quarantine", installedURL.path], timeout: 10)
        print("✅ Installed GitHub CLI to \(installedURL.path)")
        return installedURL.path
    }
}
