//
//  DottieGitHubLogin.swift
//  leanring-buddy
//
//  GitHub for Home → Tools without copying a token by hand: when the user
//  is signed in to the GitHub CLI (`gh auth login`), its token is used.
//  Also moves an old "GitHub" sign-in connector (mcp-remote to GitHub's
//  hosted server, which always failed with a 404 because GitHub doesn't
//  let apps register for a browser sign-in) over to the token setup.
//

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
    GitHub says 404 both for a name that doesn't exist and for a private repository this token can't see. Don't guess the owner: call get_me for the user's login (and list their repositories if needed), then try again with the exact owner/repo. If it still says 404, tell the user the GitHub token in Home → Tools needs access to that repository (a fine-grained token must include it, a classic token needs the repo scope).
    """
}
