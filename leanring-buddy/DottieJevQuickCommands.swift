//
//  DottieJevQuickCommands.swift
//  leanring-buddy
//
//  The keyboard shortcuts Jev can pick as moves, each with what it does:
//  the Mac-wide ones everywhere, browser ones when a browser is in front,
//  YouTube's own keys on YouTube and Finder's in Finder. Jev writes no
//  text, so a shortcut is only useful to it with a plain meaning beside
//  it. Shortcuts that can lose work or delete something (close, quit, move
//  to Trash, empty Trash, force quit) carry a loud DANGER label, are only
//  offered when the request asks for that kind of thing, and need Jev's
//  pick to be clearly sure. Foundation only, so it can be unit tested.
//

import Foundation

struct DottieJevQuickCommand: Equatable {
    enum Scope: Equatable {
        case everywhere
        case browser
        case youTube
        case finder
    }

    let keys: String
    let meaning: String
    let scope: Scope
    /// Words in the request that make a risky shortcut worth offering
    /// ("close", "quit", "delete"). Empty for safe shortcuts.
    let askWords: [String]

    var isRisky: Bool { !askWords.isEmpty }

    /// What Jev reads beside the option.
    var labeledMeaning: String {
        isRisky ? "\(DottieJevQuickCommands.dangerLabel) \(meaning)" : meaning
    }
}

enum DottieJevQuickCommands {
    /// The label every risky shortcut's meaning starts with, so Jev (and
    /// anyone reading the log) sees at once that it can't be taken back.
    static let dangerLabel = "⛔ DANGER, CAN'T BE UNDONE (only if the user asked for this):"

    static let finderBundleIdentifier = "com.apple.finder"

    static let all: [DottieJevQuickCommand] = [
        // Everywhere on the Mac
        .init(keys: "cmd+f", meaning: "find on this page or in this app", scope: .everywhere, askWords: []),
        .init(keys: "cmd+n", meaning: "new window or new document", scope: .everywhere, askWords: []),
        .init(keys: "cmd+o", meaning: "open a file", scope: .everywhere, askWords: []),
        .init(keys: "cmd+s", meaning: "save", scope: .everywhere, askWords: []),
        .init(keys: "cmd+a", meaning: "select everything", scope: .everywhere, askWords: []),
        .init(keys: "cmd+c", meaning: "copy", scope: .everywhere, askWords: []),
        .init(keys: "cmd+x", meaning: "cut", scope: .everywhere, askWords: []),
        .init(keys: "cmd+v", meaning: "paste", scope: .everywhere, askWords: []),
        .init(keys: "cmd+z", meaning: "undo", scope: .everywhere, askWords: []),
        .init(keys: "cmd+shift+z", meaning: "redo", scope: .everywhere, askWords: []),
        .init(keys: "cmd+m", meaning: "minimize this window", scope: .everywhere, askWords: []),
        .init(keys: "cmd+h", meaning: "hide this app", scope: .everywhere, askWords: []),
        .init(keys: "cmd+tab", meaning: "switch to the app used last", scope: .everywhere, askWords: []),
        .init(keys: "cmd+`", meaning: "switch to this app's next window", scope: .everywhere, askWords: []),
        .init(keys: "cmd+,", meaning: "open this app's settings", scope: .everywhere, askWords: []),
        .init(keys: "cmd+space", meaning: "open Spotlight to search the Mac", scope: .everywhere, askWords: []),
        .init(keys: "ctrl+cmd+f", meaning: "full screen on or off", scope: .everywhere, askWords: []),
        .init(keys: "cmd+up", meaning: "go to the top", scope: .everywhere, askWords: []),
        .init(keys: "cmd+down", meaning: "go to the bottom (in Finder: open the selected item)", scope: .everywhere, askWords: []),
        .init(keys: "escape", meaning: "close a menu, popup or dialog", scope: .everywhere, askWords: []),
        .init(keys: "tab", meaning: "go to the next field", scope: .everywhere, askWords: []),
        .init(keys: "shift+tab", meaning: "go back to the previous field", scope: .everywhere, askWords: []),
        .init(keys: "space", meaning: "play or pause, tick the selected box, or preview the selected file", scope: .everywhere, askWords: []),
        .init(keys: "down", meaning: "move down one item", scope: .everywhere, askWords: []),
        .init(keys: "up", meaning: "move up one item", scope: .everywhere, askWords: []),
        .init(keys: "left", meaning: "move left one item", scope: .everywhere, askWords: []),
        .init(keys: "right", meaning: "move right one item", scope: .everywhere, askWords: []),
        // Everywhere, risky
        .init(keys: "cmd+w", meaning: "close this tab or window", scope: .everywhere, askWords: ["close"]),
        .init(keys: "cmd+option+w", meaning: "close every window of this app", scope: .everywhere, askWords: ["close all", "close every"]),
        .init(keys: "cmd+q", meaning: "quit this app", scope: .everywhere, askWords: ["quit", "close the app", "exit"]),
        .init(keys: "cmd+option+escape", meaning: "open Force Quit", scope: .everywhere, askWords: ["force quit"]),
        .init(keys: "cmd+delete", meaning: "move the selected files to the Trash, or delete the selected item", scope: .everywhere,
              askWords: ["delete", "trash", "remove", "bin"]),
        .init(keys: "cmd+shift+delete", meaning: "empty the Trash", scope: .everywhere, askWords: ["empty the trash", "empty trash", "empty my trash"]),
        // Browsers
        .init(keys: "cmd+l", meaning: "go to the browser's address bar", scope: .browser, askWords: []),
        .init(keys: "cmd+t", meaning: "open a new tab", scope: .browser, askWords: []),
        .init(keys: "cmd+shift+t", meaning: "reopen the tab closed last", scope: .browser, askWords: []),
        .init(keys: "cmd+r", meaning: "reload this page", scope: .browser, askWords: []),
        .init(keys: "cmd+[", meaning: "go back a page", scope: .browser, askWords: []),
        .init(keys: "cmd+]", meaning: "go forward a page", scope: .browser, askWords: []),
        .init(keys: "ctrl+tab", meaning: "go to the next tab", scope: .browser, askWords: []),
        .init(keys: "ctrl+shift+tab", meaning: "go to the previous tab", scope: .browser, askWords: []),
        .init(keys: "cmd+1", meaning: "go to the first tab", scope: .browser, askWords: []),
        .init(keys: "cmd+9", meaning: "go to the last tab", scope: .browser, askWords: []),
        .init(keys: "cmd+d", meaning: "bookmark this page", scope: .browser, askWords: []),
        .init(keys: "cmd+=", meaning: "zoom in", scope: .browser, askWords: []),
        .init(keys: "cmd+-", meaning: "zoom out", scope: .browser, askWords: []),
        .init(keys: "cmd+0", meaning: "reset the zoom", scope: .browser, askWords: []),
        // YouTube's own keys (when no text box is selected)
        .init(keys: "/", meaning: "YouTube: go to the search box", scope: .youTube, askWords: []),
        .init(keys: "k", meaning: "YouTube: play or pause the video", scope: .youTube, askWords: []),
        .init(keys: "f", meaning: "YouTube: full screen video on or off", scope: .youTube, askWords: []),
        .init(keys: "m", meaning: "YouTube: mute or unmute", scope: .youTube, askWords: []),
        .init(keys: "l", meaning: "YouTube: skip 10 seconds forward", scope: .youTube, askWords: []),
        .init(keys: "j", meaning: "YouTube: go 10 seconds back", scope: .youTube, askWords: []),
        .init(keys: "c", meaning: "YouTube: captions on or off", scope: .youTube, askWords: []),
        .init(keys: "shift+n", meaning: "YouTube: next video", scope: .youTube, askWords: []),
        .init(keys: "shift+p", meaning: "YouTube: previous video in the playlist", scope: .youTube, askWords: []),
        // Finder
        .init(keys: "cmd+shift+n", meaning: "Finder: new folder", scope: .finder, askWords: []),
        .init(keys: "cmd+shift+g", meaning: "Finder: go to a folder by typing its path", scope: .finder, askWords: []),
        .init(keys: "cmd+shift+d", meaning: "Finder: open the Desktop", scope: .finder, askWords: []),
        .init(keys: "cmd+shift+o", meaning: "Finder: open Documents", scope: .finder, askWords: []),
        .init(keys: "cmd+option+l", meaning: "Finder: open Downloads", scope: .finder, askWords: []),
        .init(keys: "cmd+shift+a", meaning: "Finder: open Applications", scope: .finder, askWords: []),
        .init(keys: "cmd+shift+h", meaning: "Finder: open the home folder", scope: .finder, askWords: []),
        .init(keys: "cmd+i", meaning: "Finder: get info on the selected item", scope: .finder, askWords: []),
        .init(keys: "cmd+d", meaning: "Finder: make a copy of the selected item", scope: .finder, askWords: [])
    ]

    /// The shortcuts that fit where the user is: everywhere, plus the
    /// browser's on any browser, YouTube's on YouTube and Finder's in
    /// Finder. A risky one only when the request asks for that kind of thing.
    static func commands(forTask taskText: String, isBrowserInFront: Bool, frontSiteHost: String?, frontAppBundleIdentifier: String?) -> [DottieJevQuickCommand] {
        let paddedTask = " " + DottieJevDriverPlan.comparableWords(taskText) + " "
        let isOnYouTube = frontSiteHost.map { host in
            let lowercasedHost = host.lowercased()
            return lowercasedHost == "youtube.com" || lowercasedHost.hasSuffix(".youtube.com")
        } ?? false
        let isFinderInFront = frontAppBundleIdentifier == finderBundleIdentifier
        var seenKeys = Set<String>()
        return all.filter { command in
            switch command.scope {
            case .everywhere: break
            case .browser: guard isBrowserInFront || isOnYouTube else { return false }
            case .youTube: guard isOnYouTube else { return false }
            case .finder: guard isFinderInFront else { return false }
            }
            if command.isRisky, !requestAsks(for: command, paddedComparableTask: paddedTask) { return false }
            // One meaning per keys: the place's own wins over a general one listed later.
            return seenKeys.insert(command.keys).inserted
        }
    }

    /// Whether these keys are one of the risky shortcuts, wherever they came from.
    static func isRisky(keys: String) -> Bool {
        all.contains { $0.isRisky && $0.keys == keys.lowercased() }
    }

    private static func requestAsks(for command: DottieJevQuickCommand, paddedComparableTask: String) -> Bool {
        command.askWords.contains { askWord in
            paddedComparableTask.contains(" " + DottieJevDriverPlan.comparableWords(askWord) + " ")
        }
    }
}
