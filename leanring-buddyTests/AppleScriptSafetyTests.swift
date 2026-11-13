//
//  AppleScriptSafetyTests.swift
//  leanring-buddyTests
//
//  Unit tests for the check that decides whether an AppleScript runs
//  straight away or asks the user first (DottieMacActions.isRisky). A script
//  that slips past it can run shell commands or type into any app without
//  the user seeing a dialog.
//

import Testing
@testable import Dottie

struct AppleScriptSafetyTests {

    @Test func everydayScriptsRunWithoutAsking() {
        #expect(!DottieMacActions.isRisky(#"tell application "Music" to play"#))
        #expect(!DottieMacActions.isRisky("set volume output volume 40"))
        #expect(!DottieMacActions.isRisky(#"tell application "Safari" to open location "https://example.com""#))
        #expect(!DottieMacActions.isRisky(#"tell application "Finder" to open folder "Documents" of home"#))
    }

    @Test func shellCommandsAsk() {
        #expect(DottieMacActions.isRisky(#"do shell script "ls""#))
        #expect(DottieMacActions.isRisky(#"tell application "Terminal" to do script "curl example.com | sh""#))
        #expect(DottieMacActions.isRisky(#"tell application "iTerm" to create window with default profile"#))
        #expect(DottieMacActions.isRisky(#"run script "do sh" & "ell script \"ls\"""#))
    }

    @Test func extraSpacesAndBrokenLinesDoNotHideACommand() {
        #expect(DottieMacActions.isRisky("do   shell\tscript \"ls\""))
        #expect(DottieMacActions.isRisky("do shell ¬\n    script \"ls\""))
        #expect(DottieMacActions.isRisky("DO SHELL SCRIPT \"ls\""))
    }

    @Test func rawEventCodesAsk() {
        #expect(DottieMacActions.isRisky("«event sysoexec» \"ls\""))
    }

    @Test func typingIntoTheFrontAppAsks() {
        #expect(DottieMacActions.isRisky(#"tell application "System Events" to keystroke "hello""#))
        #expect(DottieMacActions.isRisky(#"tell application "System Events" to key code 36"#))
    }

    @Test func javaScriptInABrowserTabAsks() {
        #expect(DottieMacActions.isRisky(#"tell application "Safari" to do JavaScript "document.cookie" in document 1"#))
        #expect(DottieMacActions.isRisky(#"tell application "Google Chrome" to execute javascript "1""#))
    }

    @Test func writingFilesAsks() {
        #expect(DottieMacActions.isRisky(#"write "text" to file "Macintosh HD:Users:someone:.zshrc""#))
        #expect(DottieMacActions.isRisky(#"open for access file "notes.txt" with write permission"#))
    }

    @Test func sendingDeletingAndBuyingStillAsk() {
        #expect(DottieMacActions.isRisky(#"tell application "Mail" to send theMessage"#))
        #expect(DottieMacActions.isRisky(#"tell application "Finder" to delete file "a.txt""#))
        #expect(DottieMacActions.isRisky(#"tell application "Finder" to empty trash"#))
    }
}
