//
//  DottieInstantCommands.swift
//  leanring-buddy
//
//  Everyday commands Dottie does on the Mac without asking Gemini at all:
//  "open Spotify", "quit Slack", "Terminal on the left", "Chrome on my
//  other screen", "maximize Safari", "pause the music", "next song",
//  "volume up", "mute", "google cheap flights to Tokyo". The idea comes
//  from Atticus (github.com/saarthurr/atticus-mac, MIT), which runs these
//  with no AI so they happen in a blink.
//
//  Matching is deliberately strict: the whole request has to be one of
//  these shapes and every name in it has to be a real app (installed, or
//  running for quit and window moves). Anything else, or anything with an
//  extra word, goes to Gemini as before.
//
//  DottieInstantLane decides when to use these (and learned shortcuts);
//  this file only parses and runs them.
//

import AppKit
import ApplicationServices
import Foundation

enum DottieInstantCommand: Equatable {
    enum WindowPlacement: Equatable {
        case leftHalf
        case rightHalf
        case fillScreen
        case center
        case otherDisplay
        case builtInDisplay
        case externalDisplay
    }

    enum MediaAction: String, Equatable {
        case play
        case pause
        case nextTrack = "next track"
        case previousTrack = "previous track"
    }

    enum VolumeAction: Equatable {
        case up
        case down
        case setPercent(Int)
        case mute
        case unmute
    }

    case openApp(appURL: URL, appName: String)
    case openWebsite(url: URL, siteName: String)
    /// A file or folder Dottie has seen opened before (DottieKnownPlaces).
    case openPlace(url: URL, placeName: String)
    case quitApp(processIdentifier: pid_t, appName: String)
    /// nil processIdentifier: the window in front ("put this on the left").
    case placeWindow(processIdentifier: pid_t?, appName: String?, placement: WindowPlacement)
    case media(MediaAction)
    case volume(VolumeAction)
    case openSearch(url: URL, description: String)
    /// A keyboard shortcut pressed in the app in front, like "cmd+m" for
    /// "minimize". doneText is the short line shown when it's pressed.
    case pressKeys(keyCombination: String, doneText: String)

    /// What a learned or named shortcut saves for an instant command: the
    /// words, parsed again when it's replayed, so "open Notes" still works
    /// after Notes moved or updated.
    static let savedStepFunctionName = "instant_command"
}

/// The outcome of running one instant command.
enum DottieInstantCommandResult {
    /// Done; the text is the short line shown in the notch.
    case done(String)
    /// It turned out not to fit after all (no music is playing for
    /// "pause"), so the request should go to Gemini instead.
    case notHandled
    /// It was tried and failed; the text says why.
    case failed(String)
}

@MainActor
enum DottieInstantCommands {

    // MARK: - Parsing

    /// Every instant command in the request, in the order said ("close
    /// Slack and open Notes"), or nil unless every part is one.
    static func parseAll(_ requestText: String) -> [DottieInstantCommand]? {
        parseAllWithWords(requestText)?.map(\.command)
    }

    /// Like parseAll, with the words of each command, which is what a
    /// named shortcut saves.
    static func parseAllWithWords(_ requestText: String) -> [(words: String, command: DottieInstantCommand)]? {
        let normalizedRequest = DottieInstantText.normalized(requestText)
        guard !normalizedRequest.isEmpty else { return nil }
        // Whole first, so "google salt and pepper" stays one search.
        if let singleCommand = parse(normalizedRequest) { return [(normalizedRequest, singleCommand)] }

        let requestParts = DottieInstantText.splitIntoParts(normalizedRequest)
        guard requestParts.count > 1, requestParts.count <= 4 else { return nil }
        var commandsWithWords: [(words: String, command: DottieInstantCommand)] = []
        for requestPart in requestParts {
            guard let command = parse(requestPart) else { return nil }
            commandsWithWords.append((requestPart, command))
        }
        return commandsWithWords
    }

    /// One command from already-normalized words, or nil.
    static func parse(_ normalizedRequest: String) -> DottieInstantCommand? {
        parseKeyboardShortcut(normalizedRequest)
            ?? parsePressKeys(normalizedRequest)
            ?? parseMedia(normalizedRequest)
            ?? parseVolume(normalizedRequest)
            ?? parseSearch(normalizedRequest)
            ?? parseWindowPlacement(normalizedRequest)
            ?? parseQuit(normalizedRequest)
            ?? parseOpen(normalizedRequest)
    }

    /// Everyday Mac keyboard shortcuts by what they do. The whole request
    /// has to be one of these phrases, so "minimize" and "minimize this
    /// window" match but "minimize the spotify window" goes to Gemini.
    private static let keyboardShortcutPhrases: [(phrasePattern: String, keyCombination: String, doneText: String)] = [
        (#"minimi[sz]e(?: (?:this|the|that|my|current|this current))?(?: window| app)?|minimi[sz]e it|send (?:this|it) to the dock"#, "cmd+m", "Minimized the window."),
        (#"hide (?:this|the|that|current)(?: app| window)?|hide it"#, "cmd+h", "Hid the app."),
        (#"hide (?:all )?(?:the )?other (?:apps|windows)|hide everything else|hide others"#, "cmd+option+h", "Hid the other apps."),
        (#"close (?:this|the|that|current) tab|close tab"#, "cmd+w", "Closed the tab."),
        (#"close (?:this|the|that|current) window|close window"#, "cmd+w", "Closed the window."),
        (#"(?:open )?(?:a )?new tab"#, "cmd+t", "Opened a new tab."),
        (#"reopen (?:the |that |my )?(?:last )?(?:closed )?tab|undo close tab|bring (?:back )?(?:the|that) (?:last )?(?:closed )?tab(?: back)?"#, "cmd+shift+t", "Reopened the last tab."),
        (#"(?:open )?(?:a )?new window"#, "cmd+n", "Opened a new window."),
        (#"(?:go to )?(?:the )?next tab"#, "ctrl+tab", "Next tab."),
        (#"(?:go to )?(?:the )?previous tab"#, "ctrl+shift+tab", "Previous tab."),
        (#"reload|refresh|(?:reload|refresh) (?:this|the|that) (?:page|tab|site)"#, "cmd+r", "Reloaded."),
        (#"find on (?:this |the )?page|search (?:this|the) page"#, "cmd+f", "Find is open."),
        (#"undo(?: that| it| this)?"#, "cmd+z", "Undone."),
        (#"redo(?: that| it| this)?"#, "cmd+shift+z", "Redone."),
        (#"save(?: (?:it|the file|my work|the document))?"#, "cmd+s", "Saved."),
        (#"select all|select everything"#, "cmd+a", "Selected all."),
        (#"copy(?: (?:this|that|it))?"#, "cmd+c", "Copied."),
        (#"paste(?: (?:this|that|it))?"#, "cmd+v", "Pasted."),
        (#"cut(?: (?:this|that|it))?"#, "cmd+x", "Cut."),
        (#"print(?: (?:this|it|that|the page))?"#, "cmd+p", "Print is open."),
        (#"zoom in"#, "cmd+=", "Zoomed in."),
        (#"zoom out"#, "cmd+-", "Zoomed out."),
        (#"reset (?:the )?zoom|actual size"#, "cmd+0", "Zoom reset."),
        (#"(?:enter|exit|leave|toggle) full ?screen(?: mode)?|full ?screen mode"#, "ctrl+cmd+f", "Toggled full screen."),
        (#"(?:open )?spotlight"#, "cmd+space", "Spotlight is open."),
        (#"(?:open |show )?mission control"#, "ctrl+up", "Mission Control."),
        (#"(?:open )?(?:the )?emoji (?:picker|keyboard|menu)"#, "ctrl+cmd+space", "Emoji picker is open."),
        (#"lock (?:the |my )?(?:screen|mac|computer)"#, "ctrl+cmd+q", "Locked.")
    ]

    private static func parseKeyboardShortcut(_ normalizedRequest: String) -> DottieInstantCommand? {
        for keyboardShortcutPhrase in keyboardShortcutPhrases
        where normalizedRequest.range(of: "^(?:" + keyboardShortcutPhrase.phrasePattern + ")$", options: .regularExpression) != nil {
            return .pressKeys(keyCombination: keyboardShortcutPhrase.keyCombination, doneText: keyboardShortcutPhrase.doneText)
        }
        return nil
    }

    /// "press command m", "hit cmd shift t", "press escape": the keys said
    /// out loud. This is also what "when I say minimize, press command M"
    /// saves, so a taught shortcut is replayed with no AI.
    private static func parsePressKeys(_ normalizedRequest: String) -> DottieInstantCommand? {
        guard let pressVerbRange = normalizedRequest.range(of: #"^(?:press|hit)\s+"#, options: .regularExpression),
              let keyCombination = keyCombination(fromSpokenKeys: String(normalizedRequest[pressVerbRange.upperBound...])) else { return nil }
        return .pressKeys(keyCombination: keyCombination, doneText: "Pressed \(keyCombination).")
    }

    private static let spokenModifierNames: [String: String] = [
        "command": "cmd", "cmd": "cmd", "⌘": "cmd",
        "shift": "shift",
        "option": "option", "opt": "option", "alt": "option",
        "control": "ctrl", "ctrl": "ctrl",
        "fn": "fn", "function": "fn"
    ]

    private static let spokenKeyNames: [String: String] = [
        "escape": "escape", "esc": "escape", "enter": "enter", "return": "enter", "tab": "tab",
        "space": "space", "spacebar": "space", "delete": "delete", "backspace": "delete",
        "up": "up", "down": "down", "left": "left", "right": "right", "home": "home", "end": "end",
        "comma": ",", "period": ".", "dot": ".", "minus": "-", "dash": "-", "hyphen": "-",
        "equals": "=", "equal": "=", "slash": "/", "backslash": "\\", "semicolon": ";",
        "quote": "'", "backtick": "`", "grave": "`"
    ]

    /// "command shift t" → "cmd+shift+t", or nil unless it's modifiers and
    /// exactly one key Dottie can press.
    static func keyCombination(fromSpokenKeys spokenKeys: String) -> String? {
        var spokenWords = spokenKeys.lowercased()
            .replacingOccurrences(of: "+", with: " ")
            .split(separator: " ")
            .map(String.init)
            .filter { !["the", "key", "keys", "button", "arrow", "together", "at", "once"].contains($0) }
        // "command plus" is the zoom-in shortcut; "plus" between keys just joins them.
        if spokenWords.count >= 2, spokenWords.last == "plus" { spokenWords[spokenWords.count - 1] = "=" }
        spokenWords.removeAll { $0 == "plus" }
        // "page up" and "page down" are one key.
        if let pageIndex = spokenWords.firstIndex(of: "page"), pageIndex + 1 < spokenWords.count,
           ["up", "down"].contains(spokenWords[pageIndex + 1]) {
            spokenWords[pageIndex] = "page" + spokenWords[pageIndex + 1]
            spokenWords.remove(at: pageIndex + 1)
        }

        var modifierNames: [String] = []
        var keyNames: [String] = []
        for spokenWord in spokenWords {
            if let modifierName = spokenModifierNames[spokenWord] {
                if !modifierNames.contains(modifierName) { modifierNames.append(modifierName) }
            } else if let keyName = spokenKeyNames[spokenWord] {
                keyNames.append(keyName)
            } else if ["pageup", "pagedown"].contains(spokenWord)
                        || spokenWord.range(of: #"^(?:[a-z0-9]|f(?:[1-9]|1[0-2]))$"#, options: .regularExpression) != nil
                        || ["=", "-", ",", ".", "/", ";", "'", "`", "[", "]"].contains(spokenWord) {
                keyNames.append(spokenWord)
            } else {
                return nil
            }
        }
        guard keyNames.count == 1 else { return nil }
        return (modifierNames + keyNames).joined(separator: "+")
    }

    private static func parseOpen(_ normalizedRequest: String) -> DottieInstantCommand? {
        let openVerbs = ["open up ", "open ", "launch ", "start ", "go to ", "pull up ", "bring up ", "switch to "]
        guard let openVerb = openVerbs.first(where: { normalizedRequest.hasPrefix($0) }) else { return nil }
        let spokenTarget = DottieInstantText.withoutArticles(String(normalizedRequest.dropFirst(openVerb.count)))
        guard !spokenTarget.isEmpty, !DottieInstantText.containsMomentWord(spokenTarget) else { return nil }

        if let websiteURL = websiteURL(fromSpokenAddress: spokenTarget) {
            return .openWebsite(url: websiteURL, siteName: websiteURL.host ?? spokenTarget)
        }
        if let installedApp = DottieInstalledApps.shared.installedApp(matchingSpokenName: spokenTarget) {
            return .openApp(appURL: installedApp.url, appName: installedApp.name)
        }
        if let knownSite = knownWebsitesBySpokenName[spokenTarget], let knownSiteURL = URL(string: knownSite) {
            return .openWebsite(url: knownSiteURL, siteName: spokenTarget.capitalized)
        }
        // A file or folder opened before, by its name or the words used
        // for it last time.
        if let knownPlace = DottieKnownPlaces.shared.place(matchingSpokenName: spokenTarget) {
            return .openPlace(url: URL(fileURLWithPath: knownPlace.path), placeName: knownPlace.displayName)
        }
        // Not known yet: whatever opens next is what these words meant.
        DottieKnownPlaces.shared.noteUnrecognizedOpenRequest(spokenTarget: spokenTarget)
        return nil
    }

    private static func parseQuit(_ normalizedRequest: String) -> DottieInstantCommand? {
        let quitVerbs = ["quit ", "close ", "exit ", "close out of ", "shut down "]
        guard let quitVerb = quitVerbs.first(where: { normalizedRequest.hasPrefix($0) }) else { return nil }
        let spokenTarget = DottieInstantText.withoutArticles(String(normalizedRequest.dropFirst(quitVerb.count)))
        // "close this tab", "close the window": not an app, so Gemini.
        guard !spokenTarget.isEmpty, !DottieInstantText.containsMomentWord(spokenTarget),
              let runningApp = DottieInstalledApps.shared.runningApp(matchingSpokenName: spokenTarget),
              runningApp.bundleIdentifier != "com.apple.finder",
              runningApp.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return .quitApp(processIdentifier: runningApp.processIdentifier, appName: runningApp.localizedName ?? spokenTarget)
    }

    /// Phrase endings that say where a window goes, longest first so "left
    /// half" wins over "left".
    private static let placementEndings: [(ending: String, placement: DottieInstantCommand.WindowPlacement)] = {
        var endings: [(ending: String, placement: DottieInstantCommand.WindowPlacement)] = []
        for (sideWord, placement) in [("left", DottieInstantCommand.WindowPlacement.leftHalf), ("right", .rightHalf)] {
            for prefix in ["on the ", "to the ", "onto the ", ""] {
                for suffix in [" half of the screen", " half", " side of the screen", " side", ""] {
                    endings.append((ending: prefix + sideWord + suffix, placement: placement))
                }
            }
        }
        for fillEnding in ["full screen", "fullscreen", "fill the screen", "fill screen", "maximized", "bigger", "big"] {
            endings.append((fillEnding, .fillScreen))
        }
        for centerEnding in ["in the center", "in the middle", "to the center", "to the middle", "centered"] {
            endings.append((centerEnding, .center))
        }
        for screenWord in ["screen", "monitor", "display"] {
            for prefix in ["on my other ", "to my other ", "on the other ", "to the other ", "onto my other ", "on my second ", "to my second ", "to the next ", "on the next "] {
                endings.append((prefix + screenWord, .otherDisplay))
            }
            for prefix in ["on my big ", "to my big ", "on the big ", "to the big ", "on my external ", "to my external ", "on the external ", "to the external "] {
                endings.append((prefix + screenWord, .externalDisplay))
            }
        }
        for monitorEnding in ["on my monitor", "to my monitor", "on the monitor", "to the monitor"] {
            endings.append((monitorEnding, .externalDisplay))
        }
        for laptopEnding in ["on my laptop", "to my laptop", "on the laptop", "to the laptop", "on my laptop screen", "to my laptop screen", "on the laptop screen", "to the laptop screen"] {
            endings.append((laptopEnding, .builtInDisplay))
        }
        return endings.sorted { $0.ending.count > $1.ending.count }
    }()

    private static func parseWindowPlacement(_ normalizedRequest: String) -> DottieInstantCommand? {
        var remainingWords = normalizedRequest
        var placement: DottieInstantCommand.WindowPlacement?

        // "maximize chrome", "center this window"
        for (leadingVerb, leadingPlacement) in [("maximize ", DottieInstantCommand.WindowPlacement.fillScreen), ("maximise ", .fillScreen), ("center ", .center), ("centre ", .center)]
        where remainingWords.hasPrefix(leadingVerb) {
            placement = leadingPlacement
            remainingWords = String(remainingWords.dropFirst(leadingVerb.count))
            break
        }

        if placement == nil {
            for (ending, endingPlacement) in placementEndings where remainingWords.hasSuffix(" " + ending) {
                placement = endingPlacement
                remainingWords = String(remainingWords.dropLast(ending.count + 1))
                break
            }
            guard placement != nil else { return nil }
            for placementVerb in ["put ", "move ", "snap ", "send ", "throw ", "place ", "drag ", "make ", "show "] where remainingWords.hasPrefix(placementVerb) {
                remainingWords = String(remainingWords.dropFirst(placementVerb.count))
                break
            }
        }
        guard let placement else { return nil }

        let spokenTarget = DottieInstantText.withoutArticles(remainingWords)
        let frontWindowWords: Set<String> = ["this", "it", "this window", "the window", "window", "this app", "that", "that window", "my window"]
        if frontWindowWords.contains(spokenTarget) || frontWindowWords.contains(remainingWords) {
            return .placeWindow(processIdentifier: nil, appName: nil, placement: placement)
        }
        guard !spokenTarget.isEmpty, !DottieInstantText.containsMomentWord(spokenTarget),
              let runningApp = DottieInstalledApps.shared.runningApp(matchingSpokenName: spokenTarget) else { return nil }
        return .placeWindow(processIdentifier: runningApp.processIdentifier, appName: runningApp.localizedName, placement: placement)
    }

    private static let mediaPhrases: [String: DottieInstantCommand.MediaAction] = {
        var phrases: [String: DottieInstantCommand.MediaAction] = [:]
        for phrase in ["play", "play music", "play the music", "resume", "resume music", "resume the music", "unpause", "unpause the music", "keep playing", "play spotify", "resume spotify", "play my music", "resume the song", "play the song"] {
            phrases[phrase] = .play
        }
        for phrase in ["pause", "pause music", "pause the music", "stop the music", "stop music", "pause the song", "pause spotify", "pause my music", "stop the song"] {
            phrases[phrase] = .pause
        }
        for phrase in ["next", "next song", "next track", "skip", "skip song", "skip this song", "skip the song", "skip track", "skip this track", "play the next song", "next one"] {
            phrases[phrase] = .nextTrack
        }
        for phrase in ["previous song", "previous track", "last song", "go back a song", "play the previous song", "play the last song", "back a song"] {
            phrases[phrase] = .previousTrack
        }
        return phrases
    }()

    private static func parseMedia(_ normalizedRequest: String) -> DottieInstantCommand? {
        guard let mediaAction = mediaPhrases[normalizedRequest] else { return nil }
        // Only when there's a music app to talk to; otherwise "pause" may
        // mean a video, which Gemini can see.
        guard let musicAppName = DottieInstalledApps.shared.runningMusicAppName() else { return nil }
        if mediaAction == .pause && DottieInstalledApps.shared.isMusicKnownToBeNotPlaying(inAppNamed: musicAppName) { return nil }
        return .media(mediaAction)
    }

    private static func parseVolume(_ normalizedRequest: String) -> DottieInstantCommand? {
        let volumeUpPhrases: Set<String> = ["volume up", "turn the volume up", "turn up the volume", "turn it up", "louder", "increase the volume", "raise the volume", "make it louder"]
        let volumeDownPhrases: Set<String> = ["volume down", "turn the volume down", "turn down the volume", "turn it down", "quieter", "lower the volume", "decrease the volume", "make it quieter"]
        let mutePhrases: Set<String> = ["mute", "mute the sound", "mute the volume", "mute my mac", "mute sound", "mute the mac"]
        let unmutePhrases: Set<String> = ["unmute", "unmute the sound", "unmute the volume", "unmute my mac", "unmute sound", "unmute the mac"]
        if volumeUpPhrases.contains(normalizedRequest) { return .volume(.up) }
        if volumeDownPhrases.contains(normalizedRequest) { return .volume(.down) }
        if mutePhrases.contains(normalizedRequest) { return .volume(.mute) }
        if unmutePhrases.contains(normalizedRequest) { return .volume(.unmute) }

        // "set the volume to 40", "volume 40 percent", "volume to max"
        let volumeLevelPattern = #"^(?:set (?:the )?volume to|volume to|volume at|volume|turn the volume to|put the volume at|put the volume to) (\d{1,3}|max|maximum|full|half|zero)(?: percent| %|%)?$"#
        guard let levelMatch = normalizedRequest.range(of: volumeLevelPattern, options: .regularExpression) else { return nil }
        let levelWord = String(normalizedRequest[levelMatch]).components(separatedBy: " ").last { word in
            Int(word) != nil || ["max", "maximum", "full", "half", "zero"].contains(word)
        } ?? ""
        let levelPercent: Int?
        switch levelWord {
        case "max", "maximum", "full": levelPercent = 100
        case "half": levelPercent = 50
        case "zero": levelPercent = 0
        default: levelPercent = Int(levelWord)
        }
        guard let levelPercent, (0...100).contains(levelPercent) else { return nil }
        return .volume(.setPercent(levelPercent))
    }

    private static func parseSearch(_ normalizedRequest: String) -> DottieInstantCommand? {
        // "go to youtube and search up X", "search up X on youtube",
        // "look X up on google": the everyday wordings, so they open the
        // results at once instead of becoming a screen job.
        let searchVerbs = #"(?:search|look up|find|type in|look for)(?: up)?(?: for)?"#
        let searchShapes: [(pattern: String, site: String)] = [
            (#"^(?:open |go to |go on |head to |pull up )?youtube(?: and| then|,)? "# + searchVerbs + #" (.+)$"#, "youtube"),
            (#"^(?:open |go to |go on |head to |pull up )?google(?: and| then|,)? "# + searchVerbs + #" (.+)$"#, "google"),
            (#"^"# + searchVerbs + #" (.+) on youtube$"#, "youtube"),
            (#"^"# + searchVerbs + #" (.+) on google$"#, "google"),
            (#"^look (.+) up on youtube$"#, "youtube"),
            (#"^look (.+) up on google$"#, "google"),
            (#"^google (.+)$"#, "google"),
            (#"^search google for (.+)$"#, "google"),
            (#"^look up (.+) on google$"#, "google"),
            (#"^search for (.+) on google$"#, "google"),
            (#"^search youtube for (.+)$"#, "youtube"),
            (#"^search for (.+) on youtube$"#, "youtube"),
            (#"^look up (.+) on youtube$"#, "youtube"),
            (#"^find (.+) on youtube$"#, "youtube")
        ]
        for searchShape in searchShapes {
            guard let regularExpression = try? NSRegularExpression(pattern: searchShape.pattern),
                  let match = regularExpression.firstMatch(in: normalizedRequest, range: NSRange(normalizedRequest.startIndex..., in: normalizedRequest)),
                  let queryRange = Range(match.range(at: 1), in: normalizedRequest) else { continue }
            let searchQuery = String(normalizedRequest[queryRange]).trimmingCharacters(in: .whitespaces)
            guard !searchQuery.isEmpty, !DottieInstantText.containsMomentWord(searchQuery),
                  let encodedQuery = searchQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { continue }
            let searchAddress = searchShape.site == "youtube"
                ? "https://www.youtube.com/results?search_query=\(encodedQuery)"
                : "https://www.google.com/search?q=\(encodedQuery)"
            guard let searchURL = URL(string: searchAddress) else { continue }
            return .openSearch(url: searchURL, description: "\(searchShape.site == "youtube" ? "YouTube" : "Google") for “\(searchQuery)”")
        }
        return nil
    }

    /// Sites people open by name, for when no app has that name.
    private static let knownWebsitesBySpokenName: [String: String] = [
        "youtube": "https://www.youtube.com", "gmail": "https://mail.google.com", "google": "https://www.google.com",
        "github": "https://github.com", "netflix": "https://www.netflix.com", "reddit": "https://www.reddit.com",
        "twitter": "https://x.com", "chatgpt": "https://chatgpt.com", "amazon": "https://www.amazon.com",
        "wikipedia": "https://www.wikipedia.org", "instagram": "https://www.instagram.com", "facebook": "https://www.facebook.com",
        "linkedin": "https://www.linkedin.com", "google drive": "https://drive.google.com", "google docs": "https://docs.google.com",
        "google calendar": "https://calendar.google.com", "twitch": "https://www.twitch.tv", "roblox": "https://www.roblox.com",
        "claude": "https://claude.ai", "gemini": "https://gemini.google.com", "google sheets": "https://sheets.google.com",
        "youtube music": "https://music.youtube.com", "tiktok": "https://www.tiktok.com", "discord": "https://discord.com/app"
    ]

    /// "youtube.com", "youtube dot com", "docs.google.com/x" as a web
    /// address, or nil when it doesn't look like one.
    private static func websiteURL(fromSpokenAddress spokenAddress: String) -> URL? {
        let writtenAddress = spokenAddress
            .replacingOccurrences(of: " dot ", with: ".")
            .replacingOccurrences(of: " slash ", with: "/")
        guard !writtenAddress.contains(" "),
              writtenAddress.range(of: #"^(?:https?://)?[a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,}(?:/\S*)?$"#, options: .regularExpression) != nil
        else { return nil }
        return URL(string: writtenAddress.hasPrefix("http") ? writtenAddress : "https://" + writtenAddress)
    }

    // MARK: - Running

    static func run(_ command: DottieInstantCommand) async -> DottieInstantCommandResult {
        switch command {
        case .openApp(let appURL, let appName):
            return await openApp(appURL: appURL, appName: appName)
        case .openWebsite(let url, let siteName):
            return NSWorkspace.shared.open(url) ? .done("Opened \(siteName).") : .failed("Couldn't open \(siteName).")
        case .openPlace(let url, let placeName):
            guard FileManager.default.fileExists(atPath: url.path) else {
                DottieKnownPlaces.shared.forget(path: url.path)
                return .notHandled
            }
            return NSWorkspace.shared.open(url) ? .done("Opened \(placeName).") : .failed("Couldn't open \(placeName).")
        case .openSearch(let url, let description):
            return NSWorkspace.shared.open(url) ? .done("Searching \(description).") : .failed("Couldn't open the search.")
        case .quitApp(let processIdentifier, let appName):
            guard let runningApp = NSRunningApplication(processIdentifier: processIdentifier) else {
                return .done("\(appName) is already closed.")
            }
            // Asks the app to quit the normal way, so it still offers to
            // save unsaved work.
            return runningApp.terminate() ? .done("Quit \(appName).") : .failed("\(appName) didn't quit.")
        case .placeWindow(let processIdentifier, let appName, let placement):
            return placeWindow(processIdentifier: processIdentifier, appName: appName, placement: placement)
        case .media(let mediaAction):
            return await controlMusic(mediaAction)
        case .volume(let volumeAction):
            return await changeVolume(volumeAction)
        case .pressKeys(let keyCombination, let doneText):
            // Posting key presses needs Accessibility, like press_keys.
            guard DottieScreenActionPerformer.canPostEvents else {
                return .failed("I need Accessibility permission to press \(keyCombination). Turn it on in Settings, then ask again.")
            }
            return DottieScreenActionPerformer.press(keyCombination: keyCombination) ? .done(doneText) : .failed("I couldn't press \(keyCombination).")
        }
    }

    private static func openApp(appURL: URL, appName: String) async -> DottieInstantCommandResult {
        let openConfiguration = NSWorkspace.OpenConfiguration()
        openConfiguration.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: openConfiguration)
            return .done("Opened \(appName).")
        } catch {
            return .failed("Couldn't open \(appName): \(error.localizedDescription)")
        }
    }

    private static func controlMusic(_ mediaAction: DottieInstantCommand.MediaAction) async -> DottieInstantCommandResult {
        guard let musicAppName = DottieInstalledApps.shared.runningMusicAppName() else { return .notHandled }
        if mediaAction == .pause {
            // "pause" while the music is already paused probably means a
            // video, so let Gemini look.
            let playerStateResult = await DottieMacActions.runProcess(
                "/usr/bin/osascript",
                arguments: ["-e", "tell application \"\(musicAppName)\" to get player state as string"],
                timeout: 3
            )
            if playerStateResult.exitCode == 0, !playerStateResult.output.lowercased().contains("playing") {
                return .notHandled
            }
        }
        let scriptCommand: String
        switch mediaAction {
        case .play: scriptCommand = "play"
        case .pause: scriptCommand = "pause"
        case .nextTrack: scriptCommand = "next track"
        case .previousTrack: scriptCommand = "previous track"
        }
        let result = await DottieMacActions.runProcess(
            "/usr/bin/osascript",
            arguments: ["-e", "tell application \"\(musicAppName)\" to \(scriptCommand)"],
            timeout: 5
        )
        guard result.exitCode == 0 else {
            if result.errorOutput.contains("-1743") {
                return .failed("macOS needs you to let Dottie control \(musicAppName): System Settings → Privacy & Security → Automation.")
            }
            return .notHandled
        }
        switch mediaAction {
        case .play: return .done("Playing \(musicAppName).")
        case .pause: return .done("Paused \(musicAppName).")
        case .nextTrack: return .done("Next song.")
        case .previousTrack: return .done("Previous song.")
        }
    }

    private static func changeVolume(_ volumeAction: DottieInstantCommand.VolumeAction) async -> DottieInstantCommandResult {
        let volumeScript: String
        let doneText: String
        switch volumeAction {
        case .up:
            volumeScript = "set volume output muted false\nset volume output volume ((output volume of (get volume settings)) + 12)"
            doneText = "Volume up."
        case .down:
            volumeScript = "set volume output volume ((output volume of (get volume settings)) - 12)"
            doneText = "Volume down."
        case .setPercent(let levelPercent):
            volumeScript = "set volume output muted false\nset volume output volume \(levelPercent)"
            doneText = "Volume at \(levelPercent)%."
        case .mute:
            volumeScript = "set volume output muted true"
            doneText = "Muted."
        case .unmute:
            volumeScript = "set volume output muted false"
            doneText = "Unmuted."
        }
        let result = await DottieMacActions.runProcess("/usr/bin/osascript", arguments: ["-e", volumeScript], timeout: 4)
        return result.exitCode == 0 ? .done(doneText) : .failed("Couldn't change the volume.")
    }

    // MARK: - Moving windows

    private static func placeWindow(
        processIdentifier: pid_t?,
        appName: String?,
        placement: DottieInstantCommand.WindowPlacement
    ) -> DottieInstantCommandResult {
        guard AXIsProcessTrusted() else {
            return .failed("Moving windows needs Accessibility: System Settings → Privacy & Security → Accessibility → Dottie.")
        }
        let targetApp: NSRunningApplication?
        if let processIdentifier {
            targetApp = NSRunningApplication(processIdentifier: processIdentifier)
        } else {
            targetApp = NSWorkspace.shared.frontmostApplication
        }
        guard let targetApp, targetApp.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return .notHandled
        }
        let targetAppName = appName ?? targetApp.localizedName ?? "the window"
        guard let windowElement = mainWindowElement(ofProcess: targetApp.processIdentifier),
              let currentWindowFrame = appKitFrame(ofWindowElement: windowElement) else {
            return .failed("\(targetAppName) has no window to move.")
        }

        let screenUnderWindow = NSScreen.screens.first { $0.frame.contains(CGPoint(x: currentWindowFrame.midX, y: currentWindowFrame.midY)) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screenUnderWindow else { return .notHandled }

        let destinationFrame: CGRect
        let doneText: String
        switch placement {
        case .leftHalf:
            let visibleFrame = screenUnderWindow.visibleFrame
            destinationFrame = CGRect(x: visibleFrame.minX, y: visibleFrame.minY, width: visibleFrame.width / 2, height: visibleFrame.height)
            doneText = "\(targetAppName) on the left."
        case .rightHalf:
            let visibleFrame = screenUnderWindow.visibleFrame
            destinationFrame = CGRect(x: visibleFrame.midX, y: visibleFrame.minY, width: visibleFrame.width / 2, height: visibleFrame.height)
            doneText = "\(targetAppName) on the right."
        case .fillScreen:
            destinationFrame = screenUnderWindow.visibleFrame
            doneText = "\(targetAppName) fills the screen."
        case .center:
            let visibleFrame = screenUnderWindow.visibleFrame
            let centeredWidth = min(currentWindowFrame.width, visibleFrame.width)
            let centeredHeight = min(currentWindowFrame.height, visibleFrame.height)
            destinationFrame = CGRect(x: visibleFrame.midX - centeredWidth / 2, y: visibleFrame.midY - centeredHeight / 2,
                                      width: centeredWidth, height: centeredHeight)
            doneText = "\(targetAppName) in the middle."
        case .otherDisplay, .builtInDisplay, .externalDisplay:
            guard let destinationScreen = destinationScreen(for: placement, currentScreen: screenUnderWindow) else {
                return NSScreen.screens.count < 2 ? .failed("There's only one screen.") : .done("\(targetAppName) is already there.")
            }
            destinationFrame = frameMovedKeepingItsPlace(currentWindowFrame, from: screenUnderWindow.visibleFrame, to: destinationScreen.visibleFrame)
            doneText = placement == .builtInDisplay ? "\(targetAppName) on your laptop screen." : "\(targetAppName) on your other screen."
        }

        targetApp.activate()
        setAppKitFrame(destinationFrame, ofWindowElement: windowElement)
        return .done(doneText)
    }

    private static func destinationScreen(
        for placement: DottieInstantCommand.WindowPlacement,
        currentScreen: NSScreen
    ) -> NSScreen? {
        let allScreens = NSScreen.screens
        guard allScreens.count > 1 else { return nil }
        switch placement {
        case .builtInDisplay:
            let builtInScreen = allScreens.first { CGDisplayIsBuiltin($0.displayID) != 0 }
            return builtInScreen == currentScreen ? nil : builtInScreen
        case .externalDisplay:
            let externalScreens = allScreens.filter { CGDisplayIsBuiltin($0.displayID) == 0 && $0 != currentScreen }
            return externalScreens.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        default:
            guard let currentScreenIndex = allScreens.firstIndex(of: currentScreen) else { return allScreens.first }
            return allScreens[(currentScreenIndex + 1) % allScreens.count]
        }
    }

    /// The same spot and share of the screen on another display, shrunk to
    /// fit if that display is smaller.
    private static func frameMovedKeepingItsPlace(_ windowFrame: CGRect, from sourceFrame: CGRect, to destinationFrame: CGRect) -> CGRect {
        let relativeX = (windowFrame.minX - sourceFrame.minX) / max(sourceFrame.width, 1)
        let relativeY = (windowFrame.minY - sourceFrame.minY) / max(sourceFrame.height, 1)
        let movedWidth = min(windowFrame.width, destinationFrame.width)
        let movedHeight = min(windowFrame.height, destinationFrame.height)
        let movedX = min(max(destinationFrame.minX + relativeX * destinationFrame.width, destinationFrame.minX), destinationFrame.maxX - movedWidth)
        let movedY = min(max(destinationFrame.minY + relativeY * destinationFrame.height, destinationFrame.minY), destinationFrame.maxY - movedHeight)
        return CGRect(x: movedX, y: movedY, width: movedWidth, height: movedHeight)
    }

    private static func mainWindowElement(ofProcess processIdentifier: pid_t) -> AXUIElement? {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        var focusedWindowValue: AnyObject?
        if AXUIElementCopyAttributeValue(applicationElement, kAXFocusedWindowAttribute as CFString, &focusedWindowValue) == .success,
           let focusedWindowValue, CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID() {
            return DottieAccessibilityCast.element(focusedWindowValue)
        }
        var windowListValue: AnyObject?
        guard AXUIElementCopyAttributeValue(applicationElement, kAXWindowsAttribute as CFString, &windowListValue) == .success,
              let windowElements = windowListValue as? [AXUIElement] else { return nil }
        return windowElements.first
    }

    /// AX frames use a top-left origin on the primary screen; AppKit uses
    /// bottom-left. Everything here works in AppKit coordinates.
    private static var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    private static func appKitFrame(ofWindowElement windowElement: AXUIElement) -> CGRect? {
        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(windowElement, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(windowElement, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue else { return nil }
        var axPosition = CGPoint.zero
        var windowSize = CGSize.zero
        guard let positionAXValue = DottieAccessibilityCast.axValue(positionValue), AXValueGetValue(positionAXValue, .cgPoint, &axPosition),
              let sizeAXValue = DottieAccessibilityCast.axValue(sizeValue), AXValueGetValue(sizeAXValue, .cgSize, &windowSize) else { return nil }
        return CGRect(x: axPosition.x, y: primaryScreenHeight - axPosition.y - windowSize.height,
                      width: windowSize.width, height: windowSize.height)
    }

    private static func setAppKitFrame(_ appKitFrame: CGRect, ofWindowElement windowElement: AXUIElement) {
        var axPosition = CGPoint(x: appKitFrame.minX, y: primaryScreenHeight - appKitFrame.maxY)
        var windowSize = appKitFrame.size
        guard let positionValue = AXValueCreate(.cgPoint, &axPosition),
              let sizeValue = AXValueCreate(.cgSize, &windowSize) else { return }
        // Position, size, then position again: a window moving to a smaller
        // screen can refuse the size until it's there, and a resize can
        // nudge it off the spot.
        AXUIElementSetAttributeValue(windowElement, kAXPositionAttribute as CFString, positionValue)
        AXUIElementSetAttributeValue(windowElement, kAXSizeAttribute as CFString, sizeValue)
        AXUIElementSetAttributeValue(windowElement, kAXPositionAttribute as CFString, positionValue)
    }
}

// MARK: - Apps by spoken name

/// Installed and running apps, found by what people call them ("chrome"
/// for Google Chrome, "vs code" for Visual Studio Code).
@MainActor
final class DottieInstalledApps {
    static let shared = DottieInstalledApps()

    struct InstalledApp {
        let name: String
        let url: URL
    }

    private var installedAppsBySpokenName: [String: InstalledApp] = [:]
    private var installedAppsScannedAt = Date.distantPast
    private static let rescanIntervalSeconds: TimeInterval = 600
    /// "Playing", "Paused" or "Stopped" per music app, from the
    /// notifications Spotify and Music post on every change (free to
    /// listen to, no polling).
    private var musicPlayerStateByAppName: [String: String] = [:]

    private init() {
        let playerNotificationNamesByAppName = [
            "Spotify": "com.spotify.client.PlaybackStateChanged",
            "Music": "com.apple.Music.playerInfo"
        ]
        for (musicAppName, playerNotificationName) in playerNotificationNamesByAppName {
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(playerNotificationName),
                object: nil,
                queue: .main
            ) { [weak self] playerNotification in
                let playerState = playerNotification.userInfo?["Player State"] as? String
                MainActor.assumeIsolated {
                    self?.musicPlayerStateByAppName[musicAppName] = playerState
                }
            }
        }
    }

    /// True only when the music app said it isn't playing; unknown counts
    /// as maybe playing.
    func isMusicKnownToBeNotPlaying(inAppNamed musicAppName: String) -> Bool {
        guard let playerState = musicPlayerStateByAppName[musicAppName] else { return false }
        return playerState != "Playing"
    }

    /// Names people say that don't match the app's own name.
    private static let spokenNicknames: [String: String] = [
        "vs code": "visual studio code", "vscode": "visual studio code", "code": "visual studio code",
        "settings": "system settings", "system preferences": "system settings", "preferences": "system settings",
        "chrome": "google chrome", "word": "microsoft word", "excel": "microsoft excel", "powerpoint": "microsoft powerpoint",
        "outlook": "microsoft outlook", "teams": "microsoft teams", "edge": "microsoft edge", "itunes": "music",
        "app store": "app store", "facetime": "facetime", "opera": "opera gx", "photoshop": "adobe photoshop",
        "premiere": "adobe premiere pro", "after effects": "adobe after effects", "illustrator": "adobe illustrator"
    ]

    /// Leading company names people leave out ("Google Chrome" → "chrome").
    private static let droppableVendorWords: Set<String> = ["google", "microsoft", "adobe", "apple", "jetbrains", "mozilla", "the"]

    private static let appFolderURLs: [URL] = [
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "/Applications/Utilities"),
        URL(fileURLWithPath: "/System/Applications"),
        URL(fileURLWithPath: "/System/Applications/Utilities"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
    ]

    /// Lowercase letters, digits and single spaces, for comparing names.
    static func comparableName(_ appName: String) -> String {
        let lowercasedName = appName.lowercased().replacingOccurrences(of: ".app", with: "")
        let lettersAndSpaces = lowercasedName.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(lettersAndSpaces).split(separator: " ").joined(separator: " ")
    }

    /// Every way an app's name might be said.
    private static func spokenForms(ofAppName appName: String) -> Set<String> {
        let fullName = comparableName(appName)
        var forms: Set<String> = [fullName, fullName.replacingOccurrences(of: " ", with: "")]
        var nameWords = fullName.split(separator: " ").map(String.init)
        // "Adobe Photoshop 2025" → "adobe photoshop"
        while let lastWord = nameWords.last, nameWords.count > 1, Int(lastWord) != nil {
            nameWords.removeLast()
            forms.insert(nameWords.joined(separator: " "))
        }
        if nameWords.count > 1, let firstWord = nameWords.first, droppableVendorWords.contains(firstWord) {
            forms.insert(nameWords.dropFirst().joined(separator: " "))
        }
        return forms
    }

    private func rescanInstalledAppsIfStale() {
        guard Date().timeIntervalSince(installedAppsScannedAt) > Self.rescanIntervalSeconds else { return }
        installedAppsScannedAt = Date()
        var scannedApps: [String: InstalledApp] = [:]
        for appFolderURL in Self.appFolderURLs {
            let folderContents = (try? FileManager.default.contentsOfDirectory(at: appFolderURL, includingPropertiesForKeys: nil)) ?? []
            for appURL in folderContents where appURL.pathExtension == "app" {
                let appName = appURL.deletingPathExtension().lastPathComponent
                let installedApp = InstalledApp(name: appName, url: appURL)
                for spokenForm in Self.spokenForms(ofAppName: appName) where scannedApps[spokenForm] == nil {
                    scannedApps[spokenForm] = installedApp
                }
            }
        }
        installedAppsBySpokenName = scannedApps
    }

    func installedApp(matchingSpokenName spokenName: String) -> InstalledApp? {
        rescanInstalledAppsIfStale()
        let comparableSpokenName = Self.comparableName(spokenName).replacingOccurrences(of: " app", with: "")
        guard !comparableSpokenName.isEmpty else { return nil }
        if let installedApp = installedAppsBySpokenName[comparableSpokenName] { return installedApp }
        if let nickname = Self.spokenNicknames[comparableSpokenName] {
            return installedAppsBySpokenName[nickname]
        }
        return installedAppsBySpokenName[comparableSpokenName.replacingOccurrences(of: " ", with: "")]
    }

    func runningApp(matchingSpokenName spokenName: String) -> NSRunningApplication? {
        var comparableSpokenName = Self.comparableName(spokenName).replacingOccurrences(of: " app", with: "")
        guard !comparableSpokenName.isEmpty else { return nil }
        if let nickname = Self.spokenNicknames[comparableSpokenName] { comparableSpokenName = nickname }
        let regularApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        return regularApps.first { runningApp in
            guard let appName = runningApp.localizedName else { return false }
            let appSpokenForms = Self.spokenForms(ofAppName: appName)
            return appSpokenForms.contains(comparableSpokenName) || appSpokenForms.contains(comparableSpokenName.replacingOccurrences(of: " ", with: ""))
        }
    }

    /// Spotify when it's open, else Apple Music when it's open, else nil.
    func runningMusicAppName() -> String? {
        let runningBundleIdentifiers = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        if runningBundleIdentifiers.contains("com.spotify.client") { return "Spotify" }
        if runningBundleIdentifiers.contains("com.apple.Music") { return "Music" }
        return nil
    }
}

// MARK: - Comparing what was said

enum DottieInstantText {
    /// Words said before the request that don't change it.
    private static let leadingFillerPattern = #"^(?:(?:hey|ok|okay|um+|uh+|hmm+|so|dottie|please|also|and|now|then|yo|alright|right|can you|could you|would you|will you|can u|i want you to|i need you to|go ahead and|quickly)\s+)+"#
    private static let trailingFillerPattern = #"(?:\s+(?:please|for me|now|thanks|thank you|dottie|real quick|quickly))+$"#

    /// Lowercase, no punctuation (dots inside web addresses stay), no
    /// "hey dottie, can you…" or "…please".
    static func normalized(_ text: String) -> String {
        var normalizedText = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "“", with: "")
            .replacingOccurrences(of: "”", with: "")
        normalizedText = normalizedText.replacingOccurrences(of: #"[,;:!?"]|\.(?!\w)"#, with: " ", options: .regularExpression)
        normalizedText = normalizedText.split(separator: " ").joined(separator: " ")
        normalizedText = normalizedText.replacingOccurrences(of: leadingFillerPattern, with: "", options: .regularExpression)
        normalizedText = normalizedText.replacingOccurrences(of: trailingFillerPattern, with: "", options: .regularExpression)
        return normalizedText.trimmingCharacters(in: .whitespaces)
    }

    /// "close slack and open notes" → ["close slack", "open notes"].
    static func splitIntoParts(_ normalizedText: String) -> [String] {
        normalizedText
            .replacingOccurrences(of: #"\s+(?:and then|and also|then|and|after that|also)\s+"#, with: "|", options: .regularExpression)
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func withoutArticles(_ text: String) -> String {
        text.replacingOccurrences(of: #"^(?:the|my|a|an|up)\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+(?:app|application)$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Words whose meaning depends on the moment ("close this", "open that
    /// file"): never learned, and never an app name.
    private static let momentWords: Set<String> = ["this", "that", "these", "those", "it", "here", "there", "them", "him", "her", "its", "it's"]

    static func containsMomentWord(_ text: String) -> Bool {
        !momentWords.isDisjoint(with: text.split(separator: " ").map(String.init))
    }

    /// The same words in any order count as the same request.
    static func sortedWordsKey(_ normalizedText: String) -> String {
        normalizedText.split(separator: " ").map(String.init).sorted().joined(separator: " ")
    }
}
