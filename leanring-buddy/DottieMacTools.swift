//
//  DottieMacTools.swift
//  leanring-buddy
//
//  The voice tools for Dottie's direct powers: Shortcuts and AppleScript,
//  Calendar, Reminders and Contacts, the browser, and meeting notes. The
//  Live client sends every call named here to perform(functionName:…).
//

import Foundation

@MainActor
final class DottieMacTools {
    let personalData = DottiePersonalData()
    let meetingRecorder: DottieMeetingRecorder

    init(meetingRecorder: DottieMeetingRecorder) {
        self.meetingRecorder = meetingRecorder
    }

    nonisolated static let functionNames: Set<String> = [
        "run_shortcut", "list_shortcuts", "run_applescript",
        "get_schedule", "add_calendar_event", "get_reminders", "add_reminder", "complete_reminder", "find_contact",
        "browser", "meeting_notes"
    ]

    func perform(functionName: String, arguments: [String: Any]) async -> String {
        func text(_ key: String) -> String? {
            let value = (arguments[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == true ? nil : value
        }
        switch functionName {
        case "list_shortcuts":
            return await DottieMacActions.listShortcuts()
        case "run_shortcut":
            guard let name = text("name") else { return "say which shortcut." }
            return await DottieMacActions.runShortcut(named: name, input: text("input"))
        case "run_applescript":
            guard let script = text("script") else { return "the script was empty." }
            return await DottieMacActions.runAppleScript(script, purpose: text("purpose") ?? "")
        case "get_schedule":
            return await personalData.schedule(startText: text("start"), endText: text("end"))
        case "add_calendar_event":
            guard let title = text("title"), let start = text("start") else { return "an event needs a title and a start time." }
            return await personalData.addEvent(title: title, startText: start, endText: text("end"), location: text("location"), notes: text("notes"))
        case "get_reminders":
            return await personalData.reminders()
        case "add_reminder":
            guard let title = text("title") else { return "a reminder needs a title." }
            return await personalData.addReminder(title: title, dueText: text("due"), notes: text("notes"))
        case "complete_reminder":
            guard let title = text("title") else { return "say which reminder." }
            return await personalData.completeReminder(titled: title)
        case "find_contact":
            guard let name = text("name") else { return "say whose contact." }
            return await personalData.findContact(named: name)
        case "browser":
            return await DottieBrowser.perform(action: text("action") ?? "read_page", target: text("target"), value: arguments["value"] as? String)
        case "meeting_notes":
            switch text("action") ?? "status" {
            case "start": return await meetingRecorder.start()
            case "stop": return meetingRecorder.stop()
            case "latest": return meetingRecorder.latestMeetingNotes()
            default: return meetingRecorder.statusSummary()
            }
        default:
            return "unknown tool."
        }
    }

    // MARK: - Declarations

    private static func declaration(_ name: String, _ description: String, _ properties: [String: [String: Any]] = [:], required: [String] = []) -> [String: Any] {
        var parameters: [String: Any] = ["type": "OBJECT", "properties": properties]
        if !required.isEmpty { parameters["required"] = required }
        return ["name": name, "description": description, "parameters": parameters]
    }

    private static func string(_ description: String) -> [String: Any] {
        ["type": "STRING", "description": description]
    }

    private static let dateHint = "a local date and time like 2026-10-17T15:00 (or just 2026-10-17 for a whole day). work it out from today's date in your instructions."

    static let functionDeclarations: [[String: Any]] = [
        declaration(
            "list_shortcuts",
            "List the user's Apple Shortcuts by name."
        ),
        declaration(
            "run_shortcut",
            "Run one of the user's Apple Shortcuts by name, optionally with text input, and get what it returns. Use it when the user asks to run a shortcut, or when one of their shortcuts clearly does what they asked.",
            ["name": string("The shortcut's name."), "input": string("Optional text to hand the shortcut.")],
            required: ["name"]
        ),
        declaration(
            "run_applescript",
            "Run AppleScript to control Mac apps and settings directly: Music or Spotify (play, pause, next, what's playing), Finder (open folders, new folder, reveal files), Notes (make or read notes), Mail (draft emails, read the inbox), Messages, Calendar, system volume, dark mode, opening and quitting apps, arranging windows, and anything else with an AppleScript dictionary. Faster and more reliable than clicking. Only when the user asks for something. Anything that sends, deletes or buys asks the user in a dialog first. Never use it to type passwords.",
            [
                "script": string("The full AppleScript to run. Return a value at the end if you need an answer back."),
                "purpose": string("One plain sentence for the user about what it does, shown if it needs their OK.")
            ],
            required: ["script", "purpose"]
        ),
        declaration(
            "get_schedule",
            "Read the user's calendar events between two times. Use it for 'what's my day look like', 'am i free friday afternoon', 'when's my next meeting'.",
            ["start": string("Start, \(dateHint) Defaults to the start of today."), "end": string("End, same format. Defaults to the end of the start day.")]
        ),
        declaration(
            "add_calendar_event",
            "Add an event to the user's calendar.",
            [
                "title": string("What the event is."),
                "start": string("Start, \(dateHint)"),
                "end": string("End, same format. Defaults to an hour after the start."),
                "location": string("Optional place or link."),
                "notes": string("Optional notes.")
            ],
            required: ["title", "start"]
        ),
        declaration(
            "get_reminders",
            "List the user's open reminders with their due times."
        ),
        declaration(
            "add_reminder",
            "Add a reminder. With a due time it pops up on the Mac and the user's phone at that time. Use it for 'remind me to…'.",
            ["title": string("What to remind them of."), "due": string("When, \(dateHint)"), "notes": string("Optional notes.")],
            required: ["title"]
        ),
        declaration(
            "complete_reminder",
            "Tick off one of the user's open reminders.",
            ["title": string("The reminder's title, or a few words of it.")],
            required: ["title"]
        ),
        declaration(
            "find_contact",
            "Look up someone in the user's contacts: phone numbers, emails, birthday, address.",
            ["name": string("The person's name.")],
            required: ["name"]
        ),
        declaration(
            "browser",
            "Control the user's web browser directly (Safari, Chrome, Arc, Brave, Edge, Opera, Firefox and more), even when the user is in another app: never say a tab doesn't exist from the screenshot alone, check with list_tabs or switch_tab. actions: list_tabs (every open browser); read_page (the page they're on: its text, form fields and buttons, so you can answer about it or fill it in); open_url (target is the address; value 'same tab' to reuse the current tab); switch_tab and close_tab (target is a few words of the tab's title or site, or 'current'); fill (target is the field's label, value is what to put in); click (target is the button or link text); enable_page_access (only when a result says page access is off). Prefer this over clicking on screen for anything inside a web page. Only when the user asks. Never fill in passwords.",
            [
                "action": ["type": "STRING", "enum": ["list_tabs", "read_page", "open_url", "switch_tab", "close_tab", "fill", "click", "enable_page_access"], "description": "What to do."],
                "target": string("The address, tab, field or button, depending on the action."),
                "value": string("For fill: the text to enter. For open_url: 'same tab' to reuse the current tab. For switch_tab: 'confirmed' once the user said yes to switching away from the app they're in.")
            ],
            required: ["action"]
        ),
        declaration(
            "meeting_notes",
            "Meeting mode: take notes of a meeting or call the user is in by listening to their mic and their Mac's audio. start only when the user asks you to take notes or start meeting mode, never on your own. stop when they say the meeting's over or to stop; the summary with action items comes back to you later. status tells you what's been said so far (for 'what did they just say'). latest reads the notes from their most recent meeting.",
            ["action": ["type": "STRING", "enum": ["start", "stop", "status", "latest"], "description": "What to do."]],
            required: ["action"]
        )
    ]
}
