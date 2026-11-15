//
//  DottieWorkRoutes.swift
//  leanring-buddy
//
//  How helpers get things done the way Claude does: quietly in the
//  background, trying one route and moving to the next when it fails, and
//  only falling back to the screen when nothing else can do it.
//
//    1. Connected apps and APIs (MCP tools from Home → Tools, like Roblox
//       Studio, Notion or Gmail; a service's own web API).
//    2. Command-line tools, scripts, AppleScript and Shortcuts.
//    3. The user's own browser, signed in as them (DottieBrowser).
//    4. The screen, last: the helper ends its reply with a <SCREEN_JOB>
//       block, Dottie does those steps with her cursor (a screen job), and
//       the result goes back to the helper as its next message so it can
//       finish the task.
//
//  Also here: what helpers are told about making Word and Excel files, and
//  about saving what they figured out as skills for next time, and the
//  setting that lets helpers use the user's Documents, Desktop and
//  Downloads.
//

import Foundation

enum DottieWorkRoutes {
    static let helpersCanUseHomeFoldersDefaultsKey = "dottieHelpersCanUseHomeFolders"

    /// On unless the user turned it off in Settings.
    static var helpersCanUseHomeFolders: Bool {
        UserDefaults.standard.object(forKey: helpersCanUseHomeFoldersDefaultsKey) as? Bool ?? true
    }

    /// Documents, Desktop and Downloads, when helpers may use them.
    static var homeFolderURLs: [URL] {
        guard helpersCanUseHomeFolders else { return [] }
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        return ["Documents", "Desktop", "Downloads"].map { homeURL.appendingPathComponent($0, isDirectory: true) }
    }

    /// Standing instructions for every helper, on Claude and on Gemini CLI.
    static let helperInstructions = """
    # Getting it done

    Work like a capable assistant with the whole Mac at hand: do the task yourself in the background, start to finish, and only come back when it's done or truly needs the user.

    Pick the most direct route, and when one fails (an error, a missing key, a page that won't load, a tool that isn't there), don't stop and don't report it yet: move to the next route.
    1. Connected apps and APIs first. Your MCP tools are the user's connected apps (for example Roblox Studio: read the place, add and change parts, write and run Luau scripts, play-test; Notion, Gmail, GitHub, a database). Use them directly. A service with a public web API can be called with curl.
    2. Command-line tools and scripts: the shell, Python, Node, git, AppleScript (`osascript`) and Shortcuts (`shortcuts run`) for Mac apps like Numbers, Pages, Keynote, Mail, Calendar, Reminders, Notes, Finder.
    3. The user's own browser, already signed in as them (see "The user's web browser"), for websites without an API: open the page there with `open -a`, then read it by running JavaScript in it through osascript (Safari: `tell application "Safari" to do JavaScript "…" in front document`; Chrome, Edge, Brave, Arc: `tell application "Google Chrome" to execute front window's active tab javascript "…"`), for example to collect comments or posts. If the browser blocks scripting, go to the next route.
    4. The screen, last, only for what nothing above can do. Finish everything else first, then end your reply with the on-screen steps in one block:
       <SCREEN_JOB>Open Instagram in Safari, go to the post "summer drop", scroll through every comment, and report each commenter's name and what they asked for.</SCREEN_JOB>
       Write it so it stands on its own: the app or site, every step in order, and exactly what to report back. Dottie does it with her cursor and sends you the result as your next message; then carry on and finish the task.
    Try every route that fits before saying something can't be done, and then say what you tried.

    ## Live information

    Web search and fetching pages give you live, current information. Never tell the user you can't get real-time data, don't have live access, or need a setting turned on just to read the web. For prices, fares, stock, schedules, scores or anything that changes, get today's real numbers: search, then fetch the pages themselves (a booking site's own search page, the airline's or shop's site) and read the figures off them; say which site and when you checked. A page that needs a real browser goes through route 3, then a <SCREEN_JOB>, never back to the user. If, after all of that, a number still can't be confirmed, give what you found with its source and say plainly which part couldn't be confirmed and why.

    Finding the user's files: use the paths the task gives first, then Spotlight (`mdfind -name "…"`), then `find` inside the home folder only (`find ~ -maxdepth 4 …`). Never search the whole disk (`find /`): it takes minutes. If the file or folder the user named isn't there, stop and tell them what you looked for; never quietly use a different copy, an older version or a file with a similar name instead.

    Before anything that pays, sends or posts for the user, deletes their things, or uses a password, stop and ask in your reply instead; Dottie gets the user's yes (on their phone when they're away).

    ## Files people use

    - Word (.docx): write the document as clean HTML (headings, paragraphs, lists, tables), then convert it with `textutil -convert docx -inputencoding UTF-8 file.html -output file.docx` (without `-inputencoding UTF-8`, dashes, quotes and accents come out as "â€”"). Open the result's text with `textutil -convert txt -stdout file.docx` and check for "â€" before saying it's done. Pages opens it too.
    - Excel (.xlsx): Python with openpyxl (install it with `python3 -m pip install --user openpyxl` if it's missing), with real formulas (totals and summaries as =SUM/=SUMIFS on the data, not typed-in numbers), a header row and sensible column widths. If Python can't be used, make a CSV and convert it with Numbers through AppleScript (export as Microsoft Excel). Use CSV alone only as a last resort.
    - PDF: make the .docx first, then open it in Pages through AppleScript and export it as PDF.
    - Put what you make in `output/` (or where the user asked) and say the path.

    ## Learning as you go

    When you finish a kind of task you had no skill for and it took real figuring out (several steps, a site or app you had to learn, an API, which route worked), save how you did it as a skill in the skills library (see "Skills"), so the next time is quick: what the task was, the route that worked, the exact commands, tools or steps, and the pitfalls. Don't save one for a simple question or a one-off lookup. When a skill you used turned out wrong or you found a better way, update that skill.
    """

    /// Pulls a <SCREEN_JOB>…</SCREEN_JOB> block out of a helper's reply.
    /// Returns the steps and the reply without the block, or nil.
    static func screenJobRequest(in replyText: String) -> (steps: String, replyWithoutBlock: String)? {
        guard let openingTagRange = replyText.range(of: "<SCREEN_JOB>"),
              let closingTagRange = replyText.range(of: "</SCREEN_JOB>", range: openingTagRange.upperBound..<replyText.endIndex) else { return nil }
        let steps = String(replyText[openingTagRange.upperBound..<closingTagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !steps.isEmpty else { return nil }
        let replyWithoutBlock = (String(replyText[..<openingTagRange.lowerBound]) + String(replyText[closingTagRange.upperBound...]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (steps, replyWithoutBlock)
    }
}

// MARK: - The voice side

@MainActor
enum DottieWorkRouteTools: DottieToolModule {
    static var tools: [DottieTool] { [] }

    static var voicePromptSection: String {
        "for real work that spans apps, websites, files or connected apps (collect feedback from instagram into a spreadsheet and a word doc, build something in roblox studio, research and write a report), hand it to a helper with start_helper: helpers work in the background with the user's connected apps, apis, command-line tools and browser, move on to another way when one fails, and ask you to do the on-screen parts. use do_task_on_screen yourself only for a short job of clicks on the screen."
    }
}
