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
    /// Apps and windows.
    case mac
    /// Music and volume.
    case media
    case search
    case organizer

    // MARK: Picking a toolset

    private static let organizerWords: Set<String> = [
        "remind", "reminder", "reminders", "calendar", "schedule", "appointment", "meeting", "event", "agenda"
    ]
    private static let searchWords: Set<String> = [
        "google", "googling", "search", "youtube", "lookup", "bing"
    ]
    private static let mediaWords: Set<String> = [
        "music", "song", "songs", "track", "tune", "tunes", "playlist", "skip", "volume", "sound", "louder", "quieter",
        "softer", "mute", "unmute", "crank", "play", "pause", "resume", "loud", "quiet"
    ]

    /// The one toolset this ask belongs to, by its words.
    static func toolset(forNormalizedRequest normalizedRequest: String) -> DottieNeedleToolset {
        let requestWords = Set(normalizedRequest.split(separator: " ").map(String.init))
        if !requestWords.isDisjoint(with: organizerWords) { return .organizer }
        if !requestWords.isDisjoint(with: searchWords) || normalizedRequest.contains("look up") { return .search }
        if !requestWords.isDisjoint(with: mediaWords) || normalizedRequest.hasPrefix("turn it") { return .media }
        return .mac
    }

    // MARK: The tools

    var toolsJSON: String {
        switch self {
        case .mac: return Self.macToolsJSON
        case .media: return Self.mediaToolsJSON
        case .search: return Self.searchToolsJSON
        case .organizer: return Self.organizerToolsJSON
        }
    }

    static let windowPlaces = ["left", "right", "full screen", "center", "other screen", "laptop screen", "big screen"]

    private static let macToolsJSON = """
    [
      {"name": "open_app", "description": "Open, launch or start an app or a website on the Mac.",
       "parameters": {"type": "object", "properties": {
         "name": {"type": "string", "description": "the app or website, as the user said it"}},
         "required": ["name"]}},
      {"name": "quit_app", "description": "Quit, close or kill an app.",
       "parameters": {"type": "object", "properties": {
         "name": {"type": "string", "description": "the app, as the user said it"}},
         "required": ["name"]}},
      {"name": "move_window", "description": "Move or resize a window: to the left or right half, full screen, the center, or another screen.",
       "parameters": {"type": "object", "properties": {
         "app": {"type": "string", "description": "the app whose window moves; leave out for the window in front"},
         "place": {"type": "string", "enum": ["left", "right", "full screen", "center", "other screen", "laptop screen", "big screen"]}},
         "required": ["place"]}}
    ]
    """

    private static let mediaToolsJSON = """
    [
      {"name": "control_music", "description": "Play, pause, skip to the next song or go back to the previous song.",
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

    // MARK: Deciding whether to act

    /// Needle's confidence needed to act, for each toolset. Measured on a
    /// Mac with 44 everyday asks (scripts/needle-lab): right calls mostly
    /// score 0.5 to 0.9, and the wrong ones that score as high are caught
    /// by the word checks below. Reminders and events are checked so
    /// closely against the user's words that Needle's own (low) score
    /// barely matters.
    static func minimumConfidence(for toolset: DottieNeedleToolset, geminiIsDown: Bool) -> Double {
        switch toolset {
        case .mac, .media, .search: return geminiIsDown ? 0.35 : 0.5
        case .organizer: return 0
        }
    }

    /// Questions are for Gemini, even when they name an app ("how do i
    /// open a terminal").
    static func isQuestion(_ normalizedRequest: String) -> Bool {
        normalizedRequest.range(
            of: #"^(?:how|what|what's|whats|why|where|when|who|which|whose|is|are|does|do i|do you|can i|should|could i|would|explain|tell me)\b"#,
            options: .regularExpression
        ) != nil
    }

    /// The calls to act on, or nil to leave the ask to Gemini. Every call
    /// must be backed by the user's own words, not just Needle's score.
    static func callsToActOn(
        _ answer: DottieNeedleEngine.Answer,
        toolset: DottieNeedleToolset,
        normalizedRequest: String,
        geminiIsDown: Bool = false
    ) -> [DottieNeedleEngine.ToolCall]? {
        guard !isQuestion(normalizedRequest) else { return nil }
        let requestWords = Set(normalizedRequest.split(separator: " ").map(String.init))

        if toolset == .organizer {
            // Needle holds back low-scored calls; here the word checks
            // decide, so a held-back reminder still counts.
            let candidateCalls = answer.toolCalls.isEmpty ? answer.withheldToolCalls : answer.toolCalls
            guard candidateCalls.count == 1, organizerCallIsBackedByWords(candidateCalls[0], normalizedRequest: normalizedRequest, requestWords: requestWords) else { return nil }
            return candidateCalls
        }

        guard !answer.toolCalls.isEmpty,
              let confidence = answer.confidence,
              confidence >= minimumConfidence(for: toolset, geminiIsDown: geminiIsDown),
              answer.toolCalls.allSatisfy({ callIsBackedByWords($0, normalizedRequest: normalizedRequest, requestWords: requestWords) }) else { return nil }
        return answer.toolCalls
    }

    private static let playWords: Set<String> = ["play", "resume", "unpause", "on", "start", "continue"]
    private static let pauseWords: Set<String> = ["pause", "stop", "hold", "freeze"]
    private static let nextWords: Set<String> = ["next", "skip", "forward"]
    private static let previousWords: Set<String> = ["previous", "back", "last", "before", "again", "rewind"]
    private static let louderWords: Set<String> = ["up", "louder", "raise", "increase", "crank", "boost", "higher"]
    private static let quieterWords: Set<String> = ["down", "quieter", "lower", "decrease", "softer", "reduce"]
    private static let muteWords: Set<String> = ["mute", "off", "silence", "silent"]
    /// Video and screen words mean the music tools are the wrong ones.
    private static let screenMediaWords: Set<String> = ["video", "videos", "movie", "episode", "show", "clip", "reel", "reels", "short", "shorts", "tab", "page", "link"]

    private static func callIsBackedByWords(_ toolCall: DottieNeedleEngine.ToolCall, normalizedRequest: String, requestWords: Set<String>) -> Bool {
        let action = toolCall.arguments["action"] ?? ""
        switch toolCall.name {
        case "open_app", "quit_app":
            // The name must be something the user said.
            guard let spokenName = toolCall.arguments["name"]?.lowercased(), !spokenName.isEmpty else { return false }
            return normalizedRequest.contains(spokenName)
        case "move_window":
            if let spokenApp = toolCall.arguments["app"]?.lowercased(), !spokenApp.isEmpty, !normalizedRequest.contains(spokenApp) { return false }
            return true
        case "control_music":
            guard requestWords.isDisjoint(with: screenMediaWords) else { return false }
            // The action has to be the one the words say, and only that one.
            let wordsByAction: [String: Set<String>] = ["play": playWords, "pause": pauseWords, "next": nextWords, "previous": previousWords]
            let saidActions = wordsByAction.filter { !$0.value.isDisjoint(with: requestWords) }.map(\.key)
            return saidActions == [action]
        case "change_volume":
            if action == "set" { return normalizedRequest.range(of: #"\d"#, options: .regularExpression) != nil }
            if action == "unmute" { return requestWords.contains("unmute") }
            let wordsByAction: [String: Set<String>] = ["up": louderWords, "down": quieterWords, "mute": muteWords]
            let saidActions = wordsByAction.filter { !$0.value.isDisjoint(with: requestWords) }.map(\.key)
            return saidActions == [action]
        case "search_web":
            guard let query = toolCall.arguments["query"]?.lowercased(), !query.isEmpty else { return false }
            let site = toolCall.arguments["site"] ?? "google"
            return normalizedRequest.contains(query) && requestWords.contains(site == "youtube" ? "youtube" : "google") || (site == "google" && normalizedRequest.contains(query) && requestWords.contains("search") && !requestWords.contains("youtube"))
        default:
            return false
        }
    }

    private static let eventMakingWords: Set<String> = ["put", "add", "schedule", "book", "create", "make", "set", "plan"]

    private static func organizerCallIsBackedByWords(_ toolCall: DottieNeedleEngine.ToolCall, normalizedRequest: String, requestWords: Set<String>) -> Bool {
        switch toolCall.name {
        case "add_reminder":
            guard requestWords.contains("remind"), let task = toolCall.arguments["task"]?.lowercased(), task.count >= 2 else { return false }
            return normalizedRequest.contains(task)
        case "add_calendar_event":
            guard !requestWords.isDisjoint(with: eventMakingWords),
                  let title = toolCall.arguments["title"]?.lowercased(), title.count >= 2 else { return false }
            // Needle tidies titles ("Meeting with the design team"), so
            // most of its words have to come from the request.
            let titleWords = title.split(separator: " ").map(String.init)
            let saidTitleWordCount = titleWords.filter { requestWords.contains($0) }.count
            return saidTitleWordCount * 3 >= titleWords.count * 2
        default:
            return false
        }
    }

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
                // The user's own words first: Needle sometimes drops "tomorrow".
                guard let dueDate = detectedDate(in: fullRequest, now: now) ?? detectedDate(in: whenText, now: now) else { return nil }
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
                  let startDate = detectedDate(in: fullRequest, now: now) ?? detectedDate(in: whenText, now: now) else { return nil }
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

/// Needle's sentence vectors all point roughly the same way (unrelated
/// asks score 0.9 and up), so on their own they can't tell asks apart.
/// Taking away the average of many everyday sentences leaves what makes
/// each one different, which is what matching by meaning needs.
enum DottieNeedleMeaning {
    static let referenceSentences = [
        "open safari", "quit slack", "put chrome on the left", "play some music", "turn the volume down",
        "what's the weather today", "remind me to call mom", "tell me a joke", "what's on my screen",
        "write an email to my boss", "search youtube for cooking videos", "how do i fix this error",
        "move this window to my other screen", "take a screenshot", "start my focus playlist",
        "summarize this article", "translate this to spanish", "set a timer for ten minutes",
        "turn off the living room lights", "what time is it in tokyo", "open my downloads folder",
        "send this file to my phone", "click the blue button", "scroll down", "who won the game last night",
        "add lunch with sam to my calendar", "pause the video", "explain this code", "book a flight to paris",
        "show me my reminders", "close all my tabs", "make the text bigger"
    ]

    /// The average of the reference vectors (not normalized).
    static func centerVector(of referenceVectors: [[Float]]) -> [Float]? {
        guard let dimension = referenceVectors.first?.count, dimension > 0 else { return nil }
        var sum = [Float](repeating: 0, count: dimension)
        for referenceVector in referenceVectors where referenceVector.count == dimension {
            for index in 0..<dimension { sum[index] += referenceVector[index] }
        }
        return sum.map { $0 / Float(referenceVectors.count) }
    }

    /// The vector minus the center, back to unit length.
    static func centered(_ vector: [Float], center: [Float]) -> [Float] {
        guard vector.count == center.count else { return vector }
        let difference = zip(vector, center).map { $0 - $1 }
        let length = sqrt(difference.reduce(0) { $0 + $1 * $1 })
        return length > 0 ? difference.map { $0 / length } : difference
    }
}
