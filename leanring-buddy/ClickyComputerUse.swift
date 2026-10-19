//
//  ClickyComputerUse.swift
//  leanring-buddy
//
//  Lets background Clickys operate apps on the Mac: click, type, open apps
//  and use a browser. Shipped Clicky embeds cua-driver (MIT, trycua/cua) as
//  a local "computer-use" MCP server and puts a consent gate in front of it
//  (ClickyComputerUseGate): agents can always look, but they may only click
//  or type in a turn the user allowed, or after "Always allow".
//
//  The clone does the same. The build bundles cua-driver into
//  Contents/Helpers (scripts/embed-cua-driver.sh); an installed copy is the
//  fallback:
//  - Gemini CLI starts `cua-driver mcp --direct` as an MCP server, so the
//    driver runs as a child of this app and uses its Accessibility and
//    Screen Recording permissions.
//  - The driver's own policy file decides which tools work. Each turn gets
//    either the look-only policy or the look-and-act policy, passed through
//    the CLICKY_CUA_POLICY_FILE environment variable.
//  - An agent that needs to act in a look-only turn ends its reply with a
//    <COMPUTER_USE_REQUEST> block; the app shows Allow / Not now and, on
//    Allow, runs a follow-up turn with the act policy.
//

import Foundation

enum ClickyComputerUse {
    /// Name of the MCP server in Gemini CLI's settings; its tools show up
    /// to the agent as `mcp_computer-use_<tool>`.
    static let mcpServerName = "computer-use"
    /// The same driver with its clicking and typing tools, given only to
    /// turns the user allowed. Look-only turns don't get those tools at
    /// all, so their descriptions aren't re-sent with every request.
    static let actingMCPServerName = "computer-use-act"

    /// First line of a turn the user approved. The agent instructions tell
    /// it what this means.
    static let approvedTurnPrefix = "[Computer use approved for this turn]"

    private static let alwaysAllowDefaultsKey = "clickyComputerUseAlwaysAllowed"

    /// "Always allow": every turn may click and type without asking.
    static var isAlwaysAllowed: Bool {
        get { UserDefaults.standard.bool(forKey: alwaysAllowDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: alwaysAllowDefaultsKey) }
    }

    // MARK: - Locating cua-driver

    /// Finds the `cua-driver` executable: the copy the build puts in the
    /// app's Helpers folder, else one from the official installer in
    /// ~/.local/bin. CuaDriverPath in Info.plist overrides both.
    static func locateCuaDriverExecutable() -> URL? {
        locateCuaDriver()?.executableURL
    }

    /// Where the driver in use came from, for Settings.
    static var isCuaDriverBundled: Bool {
        locateCuaDriver()?.isBundled == true
    }

    private static func locateCuaDriver() -> (executableURL: URL, isBundled: Bool)? {
        if let configuredPath = AppBundleConfiguration.stringValue(forKey: "CuaDriverPath"),
           FileManager.default.isExecutableFile(atPath: configuredPath) {
            return (URL(fileURLWithPath: configuredPath), false)
        }

        let bundledDriverURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/cua-driver")
        if FileManager.default.isExecutableFile(atPath: bundledDriverURL.path) {
            return (bundledDriverURL, true)
        }

        let homeDirectoryPath = FileManager.default.homeDirectoryForCurrentUser.path
        let commonInstallPaths = [
            "\(homeDirectoryPath)/.local/bin/cua-driver",
            "/opt/homebrew/bin/cua-driver",
            "/usr/local/bin/cua-driver"
        ]
        if let foundPath = commonInstallPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return (URL(fileURLWithPath: foundPath), false)
        }
        return nil
    }

    // MARK: - Policies

    /// Tools an agent may always use: looking at apps, windows and the
    /// screen, and its own session bookkeeping.
    private static let observationToolNames = [
        "list_apps", "list_windows", "get_window_state", "get_accessibility_tree",
        "debug_window_info", "verify_state", "get_desktop_state", "get_screen_size",
        "get_cursor_position", "zoom", "get_browser_state",
        "start_session", "end_session", "get_session", "get_session_state", "list_sessions",
        "check_permissions", "health_report"
    ]

    /// Tools that change something on screen. Only allowed in approved turns.
    /// Left out on purpose: run_script, kill_app, clipboard_read, recording,
    /// replay, config changes and installers.
    private static let inputToolNames = [
        "launch_app", "bring_to_front", "set_window_frame", "invoke_menu",
        "click", "double_click", "right_click", "drag", "scroll", "move_cursor",
        "type_text", "press_key", "hotkey", "set_value", "page", "clipboard_write",
        "browser_prepare", "browser_navigate", "browser_click", "browser_type",
        "browser_pointer", "browser_dialog"
    ]

    static func observePolicyFileURL(inCLIHome cliHomeURL: URL) -> URL {
        cliHomeURL.appendingPathComponent("computer-use-observe.yaml")
    }

    static func actPolicyFileURL(inCLIHome cliHomeURL: URL) -> URL {
        cliHomeURL.appendingPathComponent("computer-use-act.yaml")
    }

    /// Writes both policy files. cua-driver denies anything not listed.
    static func writePolicyFiles(inCLIHome cliHomeURL: URL) {
        let observePolicy = policyYAML(allowedToolNames: observationToolNames, comment: "Look only. Written by Dottie; rewritten at launch.")
        let actPolicy = policyYAML(allowedToolNames: observationToolNames + inputToolNames, comment: "Look and act, for turns the user allowed. Written by Dottie; rewritten at launch.")
        try? observePolicy.write(to: observePolicyFileURL(inCLIHome: cliHomeURL), atomically: true, encoding: .utf8)
        try? actPolicy.write(to: actPolicyFileURL(inCLIHome: cliHomeURL), atomically: true, encoding: .utf8)
    }

    private static func policyYAML(allowedToolNames: [String], comment: String) -> String {
        let toolLines = allowedToolNames.map { "    - \($0)" }.joined(separator: "\n")
        return """
        # \(comment)
        allow:
          tools:
        \(toolLines)
        deny:
          tools:
            - run_script
            - kill_app

        """
    }

    /// The MCP server entry for Gemini CLI's settings. `${CLICKY_CUA_POLICY_FILE}`
    /// is expanded by Gemini CLI from the turn's environment.
    static func mcpServerSettings(cuaDriverURL: URL, canAct: Bool) -> [String: Any] {
        [
            "includeTools": canAct ? observationToolNames + inputToolNames : observationToolNames,
            "command": cuaDriverURL.path,
            "args": [
                "mcp", "--direct", "--embedded",
                "--host-bundle-id", Bundle.main.bundleIdentifier ?? "com.dottie.Dottie"
            ],
            "env": ["CUA_DRIVER_POLICY_FILE": "${CLICKY_CUA_POLICY_FILE}"],
            "trust": true,
            "timeout": 120_000
        ]
    }

    // MARK: - Requests from agents

    /// Pulls a `<COMPUTER_USE_REQUEST>…</COMPUTER_USE_REQUEST>` block out of
    /// an agent's reply. Returns the reply without it, and what the agent
    /// wants to do on screen (nil when there's no block).
    static func extractComputerUseRequest(from replyText: String) -> (replyWithoutRequest: String, requestDescription: String?) {
        guard let openingTagRange = replyText.range(of: "<COMPUTER_USE_REQUEST>"),
              let closingTagRange = replyText.range(of: "</COMPUTER_USE_REQUEST>", range: openingTagRange.upperBound..<replyText.endIndex) else {
            return (replyText, nil)
        }
        let requestDescription = String(replyText[openingTagRange.upperBound..<closingTagRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var replyWithoutRequest = replyText
        replyWithoutRequest.removeSubrange(openingTagRange.lowerBound..<closingTagRange.upperBound)
        return (
            replyWithoutRequest.trimmingCharacters(in: .whitespacesAndNewlines),
            requestDescription.isEmpty ? "Use your Mac to finish the task." : requestDescription
        )
    }

    // MARK: - Agent instructions

    /// Global instructions for every agent (Gemini CLI loads AGENTS.md from
    /// its home folder as well as from the workspace).
    static func globalAgentInstructions(isCuaDriverInstalled: Bool) -> String {
        guard isCuaDriverInstalled else {
            return """
            # Using the Mac

            You can't operate apps on this Mac right now: the computer-use driver is missing from this build of Dottie. If a task needs clicking or typing in an app, do what you can without it and tell the user that Settings in Dottie's Home explains how to add the driver.

            """
        }
        return """
        # Using the Mac

        You have tools from the `\(mcpServerName)` server (`\(actingMCPServerName)` in a turn you may act in) that operate apps on the user's Mac without taking over their screen. Use them when the task needs an app or website rather than files, for example adding a reminder, filling in a form or checking something in a signed-in site. Don't use AppleScript, `open`, or other shell tricks to drive apps.

        ## Asking first

        Looking is always allowed: `list_apps`, `list_windows`, `get_window_state` and the other read-only tools. Clicking, typing, opening apps and browsing only work in a turn whose message starts with "\(approvedTurnPrefix)". If an input tool is refused, don't retry it or look for a way around it. Finish whatever else you can, then end your reply with one block saying what you'd do on screen and why, like this:

        <COMPUTER_USE_REQUEST>Open Reminders and add "Call the dentist" for Friday at 9am.</COMPUTER_USE_REQUEST>

        Dottie shows the user Allow and Not now buttons. If they allow it, your next turn starts with "\(approvedTurnPrefix)". Never tell the user you can't use their Mac; ask with the block instead.

        Before operating an app, activate the `dottie-operating-apps` skill for the steps.

        """
    }

    /// How to operate an app with the computer-use tools. A skill (see
    /// DottieBuiltInSkills), read only by turns that operate apps.
    static let operatingAppsInstructions = """
    # Operating an app

    1. Find the app's process and window with `list_windows`, or start it with `launch_app` (pass `urls` to open a page in a browser).
    2. Call `get_window_state` for that window to get a fresh snapshot with element tokens. Snapshots go stale; take a new one in the same turn before acting.
    3. Act on elements by token (`click`, `set_value`, `type_text`, `press_key`), keeping actions in the background so the user can keep working.
    4. Check that it worked: read the action's result, then snapshot again. Don't say something is done until a snapshot shows it.

    For browser work, open your own new window in the user's default browser rather than using a tab they have open. Don't buy anything, send messages, post publicly or change account settings unless the user clearly asked for exactly that.

    """
}
