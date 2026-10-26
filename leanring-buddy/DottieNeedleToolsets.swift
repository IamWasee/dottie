//
//  DottieNeedleToolsets.swift
//  leanring-buddy
//
//  The small toolsets Needle (DottieNeedleEngine) chooses from, and how its
//  calls turn back into something Dottie already knows how to do.
//
//  Needle works best with five tools or fewer, so asks are sorted into one
//  toolset by their words first (a reminder, a search, or everything else
//  on the Mac). Its calls for Mac actions are turned into the plain words
//  of an instant command ("open safari", "put chrome on the left"), which
//  DottieInstantCommands then parses strictly as usual: the app has to be
//  real, the window has to exist. So Needle only ever widens what wording
//  is understood; it never invents an action the strict lane can't check.
//
//  Foundation only, so the Needle lab on CI can compile it.
//

import Foundation

enum DottieNeedleToolset: String, CaseIterable, Sendable {
    case mac
    case search
    case organizer

    // MARK: Picking a toolset

    private static let organizerWords: Set<String> = [
        "remind", "reminder", "reminders", "calendar", "schedule", "appointment", "meeting", "event", "agenda"
    ]
    private static let searchWords: Set<String> = [
        "google", "googling", "search", "youtube", "lookup", "bing"
    ]

    /// The one toolset this ask belongs to, by its words.
    static func toolset(forNormalizedRequest normalizedRequest: String) -> DottieNeedleToolset {
        let requestWords = Set(normalizedRequest.split(separator: " ").map(String.init))
        if !requestWords.isDisjoint(with: organizerWords) { return .organizer }
        if !requestWords.isDisjoint(with: searchWords) || normalizedRequest.contains("look up") { return .search }
        return .mac
    }

    // MARK: The tools

    var toolsJSON: String {
        switch self {
        case .mac: return Self.macToolsJSON
        case .search: return Self.searchToolsJSON
        case .organizer: return Self.organizerToolsJSON
        }
    }

    static let windowPlaces = ["left", "right", "full screen", "center", "other screen", "laptop screen", "big screen"]

    private static let macToolsJSON = """
    [
      {"name": "open_app", "description": "Open an app or a website on the Mac.",
       "parameters": {"type": "object", "properties": {
         "name": {"type": "string", "description": "the app or website, as the user said it"}},
         "required": ["name"]}},
      {"name": "quit_app", "description": "Quit or close an app.",
       "parameters": {"type": "object", "properties": {
         "name": {"type": "string", "description": "the app, as the user said it"}},
         "required": ["name"]}},
      {"name": "move_window", "description": "Move or resize a window: to the left or right half, full screen, the center, or another screen.",
       "parameters": {"type": "object", "properties": {
         "app": {"type": "string", "description": "the app whose window moves; leave out for the window in front"},
         "place": {"type": "string", "enum": ["left", "right", "full screen", "center", "other screen", "laptop screen", "big screen"]}},
         "required": ["place"]}},
      {"name": "control_music", "description": "Play, pause or skip the music.",
       "parameters": {"type": "object", "properties": {
         "action": {"type": "string", "enum": ["play", "pause", "next", "previous"]}},
         "required": ["action"]}},
      {"name": "change_volume", "description": "Turn the Mac's sound up or down, mute or unmute it, or set it to a percent.",
       "parameters": {"type": "object", "properties": {
         "action": {"type": "string", "enum": ["up", "down", "mute", "unmute", "set"]},
         "percent": {"type": "integer", "minimum": 0, "maximum": 100, "description": "only for set"}},
         "required": ["action"]}}
    ]
    """

    private static let searchToolsJSON = """
    [
      {"name": "search_web", "description": "Search Google or YouTube for something.",
       "parameters": {"type": "object", "properties": {
         "query": {"type": "string", "description": "what to search for, word for word"},
         "site": {"type": "string", "enum": ["google", "youtube"]}},
         "required": ["query", "site"]}}
    ]
    """

    private static let organizerToolsJSON = """
    [
      {"name": "add_reminder", "description": "Add a reminder, optionally at a time.",
       "parameters": {"type": "object", "properties": {
         "task": {"type": "string", "description": "what to be reminded of"},
         "when": {"type": "string", "description": "the time or day, word for word, like tomorrow at 7 pm"}},
         "required": ["task"]}},
      {"name": "add_calendar_event", "description": "Put an event or meeting on the calendar.",
       "parameters": {"type": "object", "properties": {
         "title": {"type": "string", "description": "what the event is"},
         "when": {"type": "string", "description": "the day and time, word for word, like friday at noon"},
         "place": {"type": "string", "description": "where it is"}},
         "required": ["title", "when"]}}
    ]
    """

    // MARK: Turning calls into instant command words

    /// The instant command words for one Mac or search call, like
    /// "open safari", or nil when the call isn't one.
    static func instantCommandWords(for toolCall: DottieNeedleEngine.ToolCall) -> String? {
        func argument(_ argumentName: String) -> String? {
            let value = toolCall.arguments[argumentName]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            return value.isEmpty ? nil : value
        }
        switch toolCall.name {
        case "open_app":
            return argument("name").map { "open " + $0 }
        case "quit_app":
            return argument("name").map { "quit " + $0 }
        case "move_window":
            guard let place = argument("place") else { return nil }
            let windowWords = argument("app") ?? "this window"
            let placeWords: String
            switch place {
            case "left": placeWords = "on the left"
            case "right": placeWords = "on the right"
            case "full screen": placeWords = "full screen"
            case "center": placeWords = "in the center"
            case "other screen": placeWords = "on my other screen"
            case "laptop screen": placeWords = "on my laptop"
            case "big screen": placeWords = "on my big screen"
            default: return nil
            }
            return "put \(windowWords) \(placeWords)"
        case "control_music":
            switch argument("action") {
            case "play": return "play"
            case "pause": return "pause"
            case "next": return "next song"
            case "previous": return "previous song"
            default: return nil
            }
        case "change_volume":
            switch argument("action") {
            case "up": return "volume up"
            case "down": return "volume down"
            case "mute": return "mute"
            case "unmute": return "unmute"
            case "set":
                guard let percentText = argument("percent"), let percent = Int(percentText), (0...100).contains(percent) else { return nil }
                return "set the volume to \(percent)"
            default: return nil
            }
        case "search_web":
            guard let query = argument("query") else { return nil }
            return argument("site") == "youtube" ? "search youtube for \(query)" : "google \(query)"
        default:
            return nil
        }
    }

    // MARK: Reminders and calendar

    /// The tool step (Dottie's own add_reminder / add_calendar_event) for
    /// an organizer call, with the time read on the Mac. Nil when the
    /// call isn't one or its time can't be read.
    static func organizerStep(for toolCall: DottieNeedleEngine.ToolCall, fullRequest: String, now: Date = Date()) -> (functionName: String, arguments: [String: String])? {
        let whenText = toolCall.arguments["when"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch toolCall.name {
        case "add_reminder":
            guard let task = toolCall.arguments["task"]?.trimmingCharacters(in: .whitespacesAndNewlines), !task.isEmpty else { return nil }
            var stepArguments = ["title": task]
            if !whenText.isEmpty {
                guard let dueDate = detectedDate(in: whenText, now: now) ?? detectedDate(in: fullRequest, now: now) else { return nil }
                // A day with no time ("remind me friday") pops up at 9 am,
                // not at midnight.
                let dueMoment = dueDate.hasTime
                    ? dueDate.date
                    : Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: dueDate.date) ?? dueDate.date
                stepArguments["due"] = isoLocalText(for: dueMoment, includesTime: true)
            }
            return ("add_reminder", stepArguments)
        case "add_calendar_event":
            guard let title = toolCall.arguments["title"]?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
                  let startDate = detectedDate(in: whenText, now: now) ?? detectedDate(in: fullRequest, now: now) else { return nil }
            var stepArguments = ["title": title, "start": isoLocalText(for: startDate.date, includesTime: startDate.hasTime)]
            if let place = toolCall.arguments["place"]?.trimmingCharacters(in: .whitespacesAndNewlines), !place.isEmpty {
                stepArguments["location"] = place
            }
            return ("add_calendar_event", stepArguments)
        default:
            return nil
        }
    }

    /// Apple's own date reading ("tomorrow at 7 pm", "next friday at noon").
    static func detectedDate(in text: String, now: Date) -> (date: Date, hasTime: Bool)? {
        guard !text.isEmpty, let dateDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let wholeRange = NSRange(text.startIndex..., in: text)
        guard let firstMatch = dateDetector.firstMatch(in: text, options: [], range: wholeRange), let matchedDate = firstMatch.date else { return nil }
        let matchedText = (text as NSString).substring(with: firstMatch.range).lowercased()
        let mentionsTime = matchedText.range(of: #"\d|noon|midnight|morning|afternoon|evening|tonight|night"#, options: .regularExpression) != nil
            && matchedText.range(of: #"^\s*(?:today|tomorrow|tonight|monday|tuesday|wednesday|thursday|friday|saturday|sunday|next week)\s*$"#, options: .regularExpression) == nil
        // A time already gone today means tomorrow ("remind me at 7").
        var resolvedDate = matchedDate
        if mentionsTime, resolvedDate < now, now.timeIntervalSince(resolvedDate) < 24 * 60 * 60,
           !matchedText.contains("today") {
            resolvedDate = resolvedDate.addingTimeInterval(24 * 60 * 60)
        }
        return (resolvedDate, mentionsTime)
    }

    /// The local "2026-10-17T17:00" (or "2026-10-17") form Dottie's
    /// calendar and reminder tools read.
    static func isoLocalText(for date: Date, includesTime: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = includesTime ? "yyyy-MM-dd'T'HH:mm" : "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Needle's system facts: the date makes "tomorrow" mean something.
    static func systemFacts(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd EEE HH:mm"
        return "date: \(formatter.string(from: now)); locale: \(Locale.current.identifier.replacingOccurrences(of: "_", with: "-")); device: mac"
    }
}
