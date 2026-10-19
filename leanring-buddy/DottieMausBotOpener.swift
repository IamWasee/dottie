//
//  DottieMausBotOpener.swift
//  leanring-buddy
//
//  Every "Open MausBot" button (Settings, a helper's chat, an approval card)
//  ends up here. MausBot's web page only lets in browsers that are signed
//  in to it; a fresh browser gets "unauthorized: this browser is not signed
//  in" and a form asking for a pairing code. So Dottie never opens the bare
//  address:
//    1. With the MausBot Mac app installed, the app itself comes to the front.
//    2. Otherwise Dottie mints a one-time sign-in link with MausBot's CLI and
//       opens that. `openmausbot pair --label NAME [--port N]` (openmausbot
//       0.1.115) prints, among other lines:
//         pairing code:  XXXX-XXXX-XXXX
//         this computer: http://127.0.0.1:8799/pair#code=XXXX-XXXX-XXXX
//       The /pair page signs the browser in from the code in the link by
//       itself and goes on to the workspace. Codes are single use and last
//       five minutes, so a new one is minted each time (unless this browser
//       was already signed in during this run of Dottie).
//    3. If the browser won't open, Dottie shows the code with a Copy button.
//

import AppKit
import Foundation

@MainActor
enum DottieMausBotOpener {
    /// The ports MausBot's workspace tries, in order.
    private static let workspacePorts = [8799, 18799, 28799]

    /// The browser and address this run of Dottie already signed in, so a
    /// second "Open MausBot" doesn't mint another code.
    private static var signedInBrowserBundleIdentifier: String?
    private static var signedInWorkspacePageURL: URL?

    /// Opens MausBot's web page, signed in. Starts the workspace first when
    /// it isn't running.
    static func openSignedInWorkspacePage(launcher: DottieMausBotLauncher) async {
        let usersBrowserID = DottieBrowser.usersBrowserBundleIdentifier
        if let signedInWorkspacePageURL, let usersBrowserID, usersBrowserID == signedInBrowserBundleIdentifier {
            if await DottieBrowser.openInUsersBrowser(signedInWorkspacePageURL) { return }
        }

        guard await DottieMausBot.shared.ensureWorkspaceReady(launcher: launcher) else {
            showProblem("MausBot isn't running right now. Try again in a minute, or tap Check again in Settings → Helpers.")
            return
        }
        guard let pairing = await mintSignInLink(launcher: launcher) else {
            showProblem("MausBot didn't give Dottie a sign-in link. On MausBot's page, use Settings → Remote access to pair this browser with a code.")
            return
        }
        if await DottieBrowser.openInUsersBrowser(pairing.signInLink) {
            signedInBrowserBundleIdentifier = usersBrowserID
            signedInWorkspacePageURL = pairing.workspacePageURL
            return
        }
        showPairingCode(pairing)
    }

    // MARK: Minting a sign-in link

    struct Pairing {
        let code: String
        let signInLink: URL
        let workspacePageURL: URL
    }

    /// One `openmausbot pair` per port until a workspace answers.
    private static func mintSignInLink(launcher: DottieMausBotLauncher) async -> Pairing? {
        for port in workspacePorts {
            let pairResult = await DottieMausBotCLI.run(
                ["pair", "--label", "Dottie", "--port", String(port)],
                launcher: launcher,
                timeout: 20
            )
            guard pairResult.exitCode == DottieMausBotCLI.exitDone else { continue }
            let outputText = String(decoding: pairResult.standardOutput, as: UTF8.self)
            if let pairing = parsePairing(outputText, port: port) {
                return pairing
            }
        }
        return nil
    }

    /// Reads the "pairing code:" and "this computer:" lines.
    static func parsePairing(_ outputText: String, port: Int) -> Pairing? {
        var code: String?
        var localLink: URL?
        for line in outputText.components(separatedBy: .newlines) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("pairing code:") {
                let value = trimmedLine.dropFirst("pairing code:".count).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { code = value }
            } else if trimmedLine.hasPrefix("this computer:") {
                let value = trimmedLine.dropFirst("this computer:".count).trimmingCharacters(in: .whitespaces)
                localLink = URL(string: value)
            }
        }
        guard let code, let encodedCode = code.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) else { return nil }
        guard let workspacePageURL = URL(string: "http://127.0.0.1:\(port)") else { return nil }
        let signInLink = localLink ?? URL(string: "http://127.0.0.1:\(port)/pair#code=\(encodedCode)")
        guard let signInLink else { return nil }
        return Pairing(code: code, signInLink: signInLink, workspacePageURL: workspacePageURL)
    }

    // MARK: When the link can't be opened

    /// The code, with a Copy button, for typing into MausBot's sign-in page.
    private static func showPairingCode(_ pairing: Pairing) {
        let alert = NSAlert()
        alert.messageText = "Sign in to MausBot"
        alert.informativeText = "Open \(pairing.workspacePageURL.absoluteString)/pair in your browser and type this code (it works once, for five minutes):\n\n\(pairing.code)"
        alert.addButton(withTitle: "Copy code")
        alert.addButton(withTitle: "Close")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(pairing.code, forType: .string)
        }
    }

    private static func showProblem(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't open MausBot"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
