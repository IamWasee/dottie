//
//  JevQuickCommandsTests.swift
//  leanring-buddyTests
//
//  Jev's quick commands: the Mac-wide shortcuts everywhere, the browser's
//  in a browser, YouTube's on YouTube and Finder's in Finder, risky ones
//  (close, quit, Trash, force quit) labeled DANGER, offered only when the
//  request asks, and needing a clear pick.
//

import Foundation
import Testing
@testable import Dottie

struct JevQuickCommandsTests {
    private typealias Commands = DottieJevQuickCommands
    private typealias Plan = DottieJevDriverPlan

    private func keys(_ commands: [DottieJevQuickCommand]) -> [String] { commands.map(\.keys) }

    // MARK: Where each shortcut is offered

    @Test func macWideShortcutsAreOfferedEverywhere() {
        let offered = keys(Commands.commands(forTask: "make a note", isBrowserInFront: false, frontSiteHost: nil, frontAppBundleIdentifier: "com.apple.Notes"))
        for expectedKeys in ["cmd+f", "cmd+s", "cmd+c", "cmd+v", "cmd+z", "escape", "tab", "cmd+tab", "cmd+space"] {
            #expect(offered.contains(expectedKeys))
        }
        #expect(!offered.contains("cmd+l"))
        #expect(!offered.contains("k"))
        #expect(!offered.contains("cmd+shift+n"))
    }

    @Test func youTubeSpeedKeysAreOfferedOnYouTube() throws {
        let offered = Commands.commands(forTask: "play mr beast at 1.5 speed", isBrowserInFront: true, frontSiteHost: "www.youtube.com", frontAppBundleIdentifier: "com.brave.Browser")
        let faster = try #require(offered.first { $0.keys == "shift+." })
        #expect(faster.meaning.contains("1.5x"))
        #expect(keys(offered).contains("shift+,"))
        let elsewhere = keys(Commands.commands(forTask: "play faster", isBrowserInFront: true, frontSiteHost: "vimeo.com", frontAppBundleIdentifier: "com.brave.Browser"))
        #expect(!elsewhere.contains("shift+."))
    }

    @Test func browserShortcutsComeWithABrowser() {
        let offered = keys(Commands.commands(forTask: "check my mail", isBrowserInFront: true, frontSiteHost: "mail.google.com", frontAppBundleIdentifier: "com.operasoftware.Opera"))
        for expectedKeys in ["cmd+l", "cmd+t", "cmd+r", "cmd+[", "cmd+]", "ctrl+tab", "cmd+shift+t"] {
            #expect(offered.contains(expectedKeys))
        }
        #expect(!offered.contains("k"))
    }

    @Test func youTubeKeysComeOnYouTube() {
        let offered = Commands.commands(forTask: "pause the video", isBrowserInFront: true, frontSiteHost: "www.youtube.com", frontAppBundleIdentifier: nil)
        let pause = offered.first { $0.keys == "k" }
        #expect(pause?.meaning.contains("play or pause") == true)
        #expect(keys(offered).contains("shift+n"))
        #expect(keys(offered).contains("/"))
        #expect(keys(offered).contains("cmd+l"))
    }

    @Test func youTubeCountsAsABrowserEvenWhenTheAppIsntKnown() {
        let offered = keys(Commands.commands(forTask: "x", isBrowserInFront: false, frontSiteHost: "youtube.com", frontAppBundleIdentifier: nil))
        #expect(offered.contains("cmd+l"))
        #expect(offered.contains("f"))
    }

    @Test func finderShortcutsComeInFinder() {
        let offered = Commands.commands(forTask: "open my downloads", isBrowserInFront: false, frontSiteHost: nil, frontAppBundleIdentifier: Commands.finderBundleIdentifier)
        #expect(keys(offered).contains("cmd+option+l"))
        #expect(keys(offered).contains("cmd+shift+n"))
        let duplicate = offered.first { $0.keys == "cmd+d" }
        #expect(duplicate?.meaning.contains("Finder") == true)
    }

    @Test func eachKeysAppearsOnceWherever() {
        for (isBrowser, host, bundle) in [(true, "www.youtube.com", nil), (false, nil, Commands.finderBundleIdentifier), (true, "kaggle.com", nil)] as [(Bool, String?, String?)] {
            let offered = keys(Commands.commands(forTask: "delete and close and quit", isBrowserInFront: isBrowser, frontSiteHost: host, frontAppBundleIdentifier: bundle))
            #expect(Set(offered).count == offered.count)
        }
    }

    // MARK: Risky ones

    @Test func riskyShortcutsAreLeftOutUnlessAsked() {
        let offered = keys(Commands.commands(forTask: "search for cats", isBrowserInFront: true, frontSiteHost: "google.com", frontAppBundleIdentifier: nil))
        for riskyKeys in ["cmd+w", "cmd+q", "cmd+delete", "cmd+shift+delete", "cmd+option+escape", "cmd+option+w"] {
            #expect(!offered.contains(riskyKeys))
        }
    }

    @Test func askingForItOffersOnlyThatRiskyShortcut() {
        let closeTab = keys(Commands.commands(forTask: "close this tab", isBrowserInFront: true, frontSiteHost: nil, frontAppBundleIdentifier: nil))
        #expect(closeTab.contains("cmd+w"))
        #expect(!closeTab.contains("cmd+delete"))
        let deleteFile = keys(Commands.commands(forTask: "delete invoice.pdf", isBrowserInFront: false, frontSiteHost: nil, frontAppBundleIdentifier: Commands.finderBundleIdentifier))
        #expect(deleteFile.contains("cmd+delete"))
        #expect(!deleteFile.contains("cmd+shift+delete"))
        #expect(!deleteFile.contains("cmd+q"))
        let emptyTrash = keys(Commands.commands(forTask: "empty the trash", isBrowserInFront: false, frontSiteHost: nil, frontAppBundleIdentifier: nil))
        #expect(emptyTrash.contains("cmd+shift+delete"))
        let quit = keys(Commands.commands(forTask: "quit spotify", isBrowserInFront: false, frontSiteHost: nil, frontAppBundleIdentifier: nil))
        #expect(quit.contains("cmd+q"))
    }

    @Test func riskyShortcutsCarryTheDangerLabel() {
        let risky = Commands.all.filter(\.isRisky)
        #expect(risky.count >= 5)
        for command in risky {
            #expect(command.labeledMeaning.hasPrefix(Commands.dangerLabel))
        }
        for command in Commands.all where !command.isRisky {
            #expect(!command.labeledMeaning.contains("DANGER"))
            #expect(command.labeledMeaning == command.meaning)
        }
    }

    @Test func riskyKeysAreKnownWhateverTheirCase() {
        #expect(Commands.isRisky(keys: "cmd+q"))
        #expect(Commands.isRisky(keys: "CMD+W"))
        #expect(Commands.isRisky(keys: "cmd+delete"))
        #expect(!Commands.isRisky(keys: "cmd+c"))
        #expect(!Commands.isRisky(keys: "k"))
    }

    // MARK: Inside Jev's options and decisions

    @Test func jevSeesTheDangerLabelInItsOptions() throws {
        let options = Plan.options(screenTexts: [], textPieces: [], siteAddresses: [], appNames: [], alreadyTriedSignatures: [],
                                   taskText: "close this tab", isBrowserInFront: true)
        let closeOption = try #require(options.first { option in
            if case .pressKeys(let pressedKeys, _) = option.move { return pressedKeys == "cmd+w" }
            return false
        })
        #expect(closeOption.move.description.contains("DANGER"))
        #expect(closeOption.move.description.contains("close this tab or window"))
    }

    @Test func aRiskyShortcutNeedsAClearPick() {
        let unsure = Plan.Answer(move: .pressKeys(keys: "cmd+delete", meaning: "x"), probability: 0.4, confidence: 0.6, doneProbability: 0.1)
        #expect(Plan.decision(for: unsure) == .unsure)
        let sure = Plan.Answer(move: .pressKeys(keys: "cmd+delete", meaning: "x"), probability: 0.7, confidence: 0.6, doneProbability: 0.1)
        #expect(Plan.decision(for: sure) == .act(.pressKeys(keys: "cmd+delete", meaning: "x")))
        let safe = Plan.Answer(move: .pressKeys(keys: "k", meaning: "x"), probability: 0.4, confidence: 0.6, doneProbability: 0.1)
        #expect(Plan.decision(for: safe) == .act(.pressKeys(keys: "k", meaning: "x")))
    }

    @Test func everyShortcutsKeysArePressable() {
        let knownKeyNames: Set<String> = Set("abcdefghijklmnopqrstuvwxyz0123456789".map(String.init))
            .union(["return", "tab", "space", "escape", "delete", "up", "down", "left", "right", "[", "]", "-", "=", ",", "/", "`"])
        for command in Commands.all {
            let keyName = String(command.keys.split(separator: "+").last ?? "")
            #expect(knownKeyNames.contains(keyName), "\(command.keys)")
        }
    }

    @Test func optionsStayUnderJevsLimitOnYouTube() {
        let manyTexts = (0..<300).map { Plan.ScreenText(text: "Video \($0)", centerX: 10, centerY: 10) }
        let options = Plan.options(screenTexts: manyTexts, textPieces: ["mr beast"], siteAddresses: ["youtube.com"], appNames: [], alreadyTriedSignatures: [],
                                   frontSiteHost: "www.youtube.com", taskText: "play a mr beast video", isBrowserInFront: true)
        #expect(options.count <= Plan.maximumOptions)
    }

    @Test func pickingShortcutsIsQuick() {
        let startedAt = Date()
        for _ in 0..<2000 {
            _ = Commands.commands(forTask: "close this tab and delete the file", isBrowserInFront: true, frontSiteHost: "www.youtube.com", frontAppBundleIdentifier: nil)
        }
        #expect(Date().timeIntervalSince(startedAt) < 1.0)
    }
}
