//
//  HelperFollowThroughTests.swift
//  leanring-buddyTests
//
//  Unit tests for DottieHelperHandOffCheck and DottieRecentWorkNote: when
//  voice Dottie has promised a helper but never started one, and what she
//  is told about the helpers' recent work so "open that file" goes back to
//  the helper that did it.
//

import Foundation
import Testing
@testable import Dottie

struct HelperHandOffClaimTests {
    let helperNames = ["Jarvis", "Researcher"]

    @Test func namingAHelperThatIsTakingTheJobIsAClaim() {
        #expect(DottieHelperHandOffCheck.answerClaimsHandOff("Okay, I've asked Jarvis to fix the numbers.", helperNames: helperNames))
        #expect(DottieHelperHandOffCheck.answerClaimsHandOff("Got it, a helper is on it.", helperNames: helperNames))
        #expect(DottieHelperHandOffCheck.answerClaimsHandOff("I’ll have the researcher look into it.", helperNames: helperNames))
    }

    @Test func aFinishedJobOrARefusalIsNotAClaim() {
        #expect(!DottieHelperHandOffCheck.answerClaimsHandOff("Jarvis finished your budget file.", helperNames: helperNames))
        #expect(!DottieHelperHandOffCheck.answerClaimsHandOff("I can't start a helper right now.", helperNames: helperNames))
    }

    @Test func answersWithoutAHelperAreNotClaims() {
        #expect(!DottieHelperHandOffCheck.answerClaimsHandOff("Sure, opening Safari.", helperNames: helperNames))
        #expect(!DottieHelperHandOffCheck.answerClaimsHandOff("Opening dottie dot com.", helperNames: helperNames))
    }

    @Test func shortNamesAreNotLookedForInsideSentences() {
        #expect(!DottieHelperHandOffCheck.answerClaimsHandOff("I'm starting the timer, al is fine.", helperNames: ["Al"]))
    }
}

struct HelperHandOffUserAskTests {
    let helperNames = ["Jarvis"]

    @Test func askingForAHelperOrOneByNameIsSeen() {
        #expect(DottieHelperHandOffCheck.userAskedForHelper("have a helper make me a website", helperNames: helperNames))
        #expect(DottieHelperHandOffCheck.userAskedForHelper("ask Jarvis to open the file", helperNames: helperNames))
        #expect(DottieHelperHandOffCheck.userAskedForHelper("send this to the dots", helperNames: helperNames))
    }

    @Test func everydayAsksAreNot() {
        #expect(!DottieHelperHandOffCheck.userAskedForHelper("open safari", helperNames: helperNames))
        #expect(!DottieHelperHandOffCheck.userAskedForHelper("get me the weather", helperNames: helperNames))
    }

    @Test func askingAsAQuestionOrByNameCounts() {
        #expect(DottieHelperHandOffCheck.userAskedForHelper("can one of my helpers make me a packing list for a beach trip?", helperNames: helperNames))
        #expect(DottieHelperHandOffCheck.userAskedForHelper("Jarvis, look up the 3 cheapest flights from Dhaka to Bangkok", helperNames: helperNames))
        #expect(DottieHelperHandOffCheck.userAskedForHelper("hey jarvis: find me a flight", helperNames: helperNames))
    }

    @Test func questionsAboutHelpersArentJobs() {
        #expect(!DottieHelperHandOffCheck.userAskedForHelper("what can my helpers do?", helperNames: helperNames))
        #expect(!DottieHelperHandOffCheck.userAskedForHelper("I talked about Jarvis, the movie", helperNames: helperNames))
    }
}

struct HelperHandOffNudgeTests {
    let helperNames = ["Jarvis", "Researcher"]

    @Test func aPromiseWithNoStartHelperNeedsANudge() {
        #expect(DottieHelperHandOffCheck.needsHandOffNudge(
            userText: "fix the numbers in my budget",
            modelTranscript: "On it, I've asked Jarvis to fix them.",
            calledFunctionNames: [],
            helperNames: helperNames,
            busyHelperNames: []
        ))
    }

    @Test func aPromiseThatReallyStartedAHelperIsFine() {
        #expect(!DottieHelperHandOffCheck.needsHandOffNudge(
            userText: "fix the numbers in my budget",
            modelTranscript: "On it, I've asked Jarvis to fix them.",
            calledFunctionNames: ["start_helper"],
            helperNames: helperNames,
            busyHelperNames: []
        ))
        #expect(!DottieHelperHandOffCheck.needsHandOffNudge(
            userText: "build me a site with a team",
            modelTranscript: "A team of helpers is on it.",
            calledFunctionNames: ["use_tool", "start_team"],
            helperNames: helperNames,
            busyHelperNames: []
        ))
    }

    @Test func talkingAboutABusyHelperIsAStatusNotAPromise() {
        #expect(!DottieHelperHandOffCheck.needsHandOffNudge(
            userText: "how's it going",
            modelTranscript: "Jarvis is working on your spreadsheet now.",
            calledFunctionNames: [],
            helperNames: helperNames,
            busyHelperNames: ["Jarvis"]
        ))
    }

    @Test func aQuestionThatCheckedOnHelpersIsLeftAlone() {
        #expect(!DottieHelperHandOffCheck.needsHandOffNudge(
            userText: "ask Jarvis how it's going",
            modelTranscript: "Jarvis is on it, about halfway.",
            calledFunctionNames: ["check_helper"],
            helperNames: helperNames,
            busyHelperNames: []
        ))
    }

    @Test func askingForAHelperAndGettingNoneNeedsANudge() {
        #expect(DottieHelperHandOffCheck.needsHandOffNudge(
            userText: "have a helper research cafés near me",
            modelTranscript: "Sure thing.",
            calledFunctionNames: [],
            helperNames: helperNames,
            busyHelperNames: []
        ))
    }

    @Test func askingBackWhichHelperIsFine() {
        #expect(!DottieHelperHandOffCheck.needsHandOffNudge(
            userText: "have a helper do it",
            modelTranscript: "Which one should do it, Jarvis or Researcher?",
            calledFunctionNames: [],
            helperNames: helperNames,
            busyHelperNames: []
        ))
    }

    @Test func theNudgeSaysWhatWentWrongAndNeverPointsAtTheBrain() {
        let promisedText = DottieHelperHandOffCheck.nudgeText(answerClaimedHandOff: true)
        #expect(promisedText.contains("you told the user a helper is doing this"))
        #expect(promisedText.contains("start_helper"))
        #expect(promisedText.contains("never the second brain"))
        #expect(DottieHelperHandOffCheck.nudgeText(answerClaimedHandOff: false).contains("the user asked for a helper"))
    }
}

struct RecentWorkNoteTests {
    @Test func pathsInAHelpersStepsAreFound() {
        #expect(DottieRecentWorkNote.filePaths(in: "write_file · /Users/me/Documents/Budget.xlsx") == ["/Users/me/Documents/Budget.xlsx"])
        #expect(DottieRecentWorkNote.filePaths(in: "I updated ~/Desktop/report.docx.") == ["~/Desktop/report.docx"])
    }

    @Test func aQuotedPathWithSpacesAndALongExtensionIsFound() {
        #expect(DottieRecentWorkNote.filePaths(in: "edit · path: \"/Users/me/My Files/Q2 numbers.numbers\"") == ["/Users/me/My Files/Q2 numbers.numbers"])
    }

    @Test func commandsAndFoldersAreNotFiles() {
        #expect(DottieRecentWorkNote.filePaths(in: "run_shell_command · ls -la").isEmpty)
        #expect(DottieRecentWorkNote.filePaths(in: "read · /Users/me/Downloads/").isEmpty)
    }

    @Test func theNoteListsTheNewestJobsWithTheirFiles() throws {
        let now = Date()
        let entries = [
            DottieRecentHelperWork(helperName: "Researcher", status: "finished 2 h ago", taskText: "find cafés", taskStartedAt: now.addingTimeInterval(-7200), touchedFilePaths: [], latestReply: nil),
            DottieRecentHelperWork(helperName: "Jarvis", status: "finished 4 min ago", taskText: "edit my budget numbers", taskStartedAt: now.addingTimeInterval(-240), touchedFilePaths: ["/Users/me/Budget.xlsx"], latestReply: "Done, updated the totals.")
        ]
        let noteText = try #require(DottieRecentWorkNote.noteText(entries: entries, now: now))
        let jarvisLineRange = try #require(noteText.range(of: "- Jarvis"))
        let researcherLineRange = try #require(noteText.range(of: "- Researcher"))
        #expect(jarvisLineRange.lowerBound < researcherLineRange.lowerBound)
        #expect(noteText.contains("files: /Users/me/Budget.xlsx"))
        #expect(noteText.contains("never the one to open or redo a helper's work"))
    }

    @Test func oldJobsAreLeftOutAndNoJobsMeansNoNote() {
        let now = Date()
        let oldEntry = DottieRecentHelperWork(helperName: "Jarvis", status: "finished yesterday", taskText: "old job", taskStartedAt: now.addingTimeInterval(-86_400), touchedFilePaths: [], latestReply: nil)
        #expect(DottieRecentWorkNote.noteText(entries: [oldEntry], now: now) == nil)
        #expect(DottieRecentWorkNote.noteText(entries: [], now: now) == nil)
    }
}
