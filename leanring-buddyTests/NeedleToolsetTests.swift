//
//  NeedleToolsetTests.swift
//  leanring-buddyTests
//
//  Unit tests for DottieNeedleToolset: which small toolset an ask goes to,
//  the word checks that decide whether the on-Mac model's call is acted on,
//  and how a call becomes instant command words or a reminder step. A
//  mistake here makes the Mac do something the user never said.
//

import Foundation
import Testing
@testable import Dottie

struct NeedleToolsetPickingTests {

    @Test func reminderAndCalendarWordsGoToTheOrganizer() {
        #expect(DottieNeedleToolset.toolset(forNormalizedRequest: "remind me to call mom") == .organizer)
        #expect(DottieNeedleToolset.toolset(forNormalizedRequest: "add lunch with sam to my calendar") == .organizer)
    }

    @Test func searchWordsGoToSearch() {
        #expect(DottieNeedleToolset.toolset(forNormalizedRequest: "google red pandas") == .search)
        #expect(DottieNeedleToolset.toolset(forNormalizedRequest: "look up red pandas") == .search)
    }

    @Test func musicAndVolumeWordsGoToMedia() {
        #expect(DottieNeedleToolset.toolset(forNormalizedRequest: "skip this song") == .media)
        #expect(DottieNeedleToolset.toolset(forNormalizedRequest: "turn it up") == .media)
    }

    @Test func everythingElseGoesToAppsAndWindows() {
        #expect(DottieNeedleToolset.toolset(forNormalizedRequest: "open safari") == .mac)
    }

    @Test func questionsAreNoticedByTheirFirstWords() {
        #expect(DottieNeedleToolset.isQuestion("how do i open a terminal"))
        #expect(DottieNeedleToolset.isQuestion("what's playing"))
        #expect(!DottieNeedleToolset.isQuestion("open safari"))
        // "whatsapp" starts with "whats" but is not a question word.
        #expect(!DottieNeedleToolset.isQuestion("whatsapp open"))
    }
}

struct NeedleCallCheckingTests {

    private func answer(
        toolCalls: [DottieNeedleEngine.ToolCall],
        withheldToolCalls: [DottieNeedleEngine.ToolCall] = [],
        confidence: Double? = 0.8
    ) -> DottieNeedleEngine.Answer {
        DottieNeedleEngine.Answer(
            toolCalls: toolCalls,
            withheldToolCalls: withheldToolCalls,
            confidence: confidence,
            reasoning: "",
            milliseconds: 0
        )
    }

    @Test func openingAnAppTheUserNamedIsActedOn() {
        let openSafariCall = DottieNeedleEngine.ToolCall(name: "open_app", arguments: ["name": "Safari"])

        let callsToActOn = DottieNeedleToolset.callsToActOn(
            answer(toolCalls: [openSafariCall]),
            toolset: .mac,
            normalizedRequest: "fire up safari"
        )

        #expect(callsToActOn == [openSafariCall])
    }

    @Test func anAppTheUserNeverSaidIsNotOpened() {
        let openChromeCall = DottieNeedleEngine.ToolCall(name: "open_app", arguments: ["name": "Chrome"])

        let callsToActOn = DottieNeedleToolset.callsToActOn(
            answer(toolCalls: [openChromeCall]),
            toolset: .mac,
            normalizedRequest: "fire up safari"
        )

        #expect(callsToActOn == nil)
    }

    @Test func aQuestionIsLeftToGeminiEvenWithAConfidentCall() {
        let openTerminalCall = DottieNeedleEngine.ToolCall(name: "open_app", arguments: ["name": "terminal"])

        let callsToActOn = DottieNeedleToolset.callsToActOn(
            answer(toolCalls: [openTerminalCall], confidence: 0.95),
            toolset: .mac,
            normalizedRequest: "how do i open a terminal"
        )

        #expect(callsToActOn == nil)
    }

    @Test func lowConfidenceIsOnlyEnoughWhileGeminiIsDown() {
        let openSafariCall = DottieNeedleEngine.ToolCall(name: "open_app", arguments: ["name": "safari"])
        let unsureAnswer = answer(toolCalls: [openSafariCall], confidence: 0.4)

        #expect(DottieNeedleToolset.callsToActOn(unsureAnswer, toolset: .mac, normalizedRequest: "fire up safari") == nil)
        #expect(DottieNeedleToolset.callsToActOn(unsureAnswer, toolset: .mac, normalizedRequest: "fire up safari", geminiIsDown: true) == [openSafariCall])
    }

    @Test func anAnswerWithNoConfidenceIsNotActedOn() {
        let openSafariCall = DottieNeedleEngine.ToolCall(name: "open_app", arguments: ["name": "safari"])

        let callsToActOn = DottieNeedleToolset.callsToActOn(
            answer(toolCalls: [openSafariCall], confidence: nil),
            toolset: .mac,
            normalizedRequest: "fire up safari"
        )

        #expect(callsToActOn == nil)
    }

    @Test func musicActionMustBeTheOneTheWordsSay() {
        let nextSongCall = DottieNeedleEngine.ToolCall(name: "control_music", arguments: ["action": "next"])
        let pauseCall = DottieNeedleEngine.ToolCall(name: "control_music", arguments: ["action": "pause"])

        #expect(DottieNeedleToolset.callsToActOn(answer(toolCalls: [nextSongCall]), toolset: .media, normalizedRequest: "skip this song") == [nextSongCall])
        #expect(DottieNeedleToolset.callsToActOn(answer(toolCalls: [pauseCall]), toolset: .media, normalizedRequest: "skip this song") == nil)
    }

    @Test func wordsForTwoMusicActionsAtOnceAreLeftToGemini() {
        let nextSongCall = DottieNeedleEngine.ToolCall(name: "control_music", arguments: ["action": "next"])

        let callsToActOn = DottieNeedleToolset.callsToActOn(
            answer(toolCalls: [nextSongCall]),
            toolset: .media,
            normalizedRequest: "play the next song"
        )

        #expect(callsToActOn == nil)
    }

    @Test func pausingAVideoIsNotAMusicCommand() {
        let pauseCall = DottieNeedleEngine.ToolCall(name: "control_music", arguments: ["action": "pause"])

        let callsToActOn = DottieNeedleToolset.callsToActOn(
            answer(toolCalls: [pauseCall]),
            toolset: .media,
            normalizedRequest: "pause the video"
        )

        #expect(callsToActOn == nil)
    }

    @Test func settingTheVolumeNeedsANumberInTheWords() {
        let setVolumeCall = DottieNeedleEngine.ToolCall(name: "change_volume", arguments: ["action": "set", "percent": "40"])

        #expect(DottieNeedleToolset.callsToActOn(answer(toolCalls: [setVolumeCall]), toolset: .media, normalizedRequest: "volume to 40") == [setVolumeCall])
        #expect(DottieNeedleToolset.callsToActOn(answer(toolCalls: [setVolumeCall]), toolset: .media, normalizedRequest: "volume please") == nil)
    }

    @Test func searchOnlyOpensWhenTheUserNamedTheSite() {
        let googleCall = DottieNeedleEngine.ToolCall(name: "search_web", arguments: ["query": "red pandas", "site": "google"])
        let youTubeCall = DottieNeedleEngine.ToolCall(name: "search_web", arguments: ["query": "red pandas", "site": "youtube"])

        #expect(DottieNeedleToolset.callsToActOn(answer(toolCalls: [googleCall]), toolset: .search, normalizedRequest: "google red pandas") == [googleCall])
        #expect(DottieNeedleToolset.callsToActOn(answer(toolCalls: [googleCall]), toolset: .search, normalizedRequest: "search for red pandas") == nil)
        #expect(DottieNeedleToolset.callsToActOn(answer(toolCalls: [youTubeCall]), toolset: .search, normalizedRequest: "google red pandas") == nil)
    }

    @Test func aHeldBackReminderStillCountsWhenTheWordsBackItUp() {
        let reminderCall = DottieNeedleEngine.ToolCall(name: "add_reminder", arguments: ["task": "call mom"])

        let callsToActOn = DottieNeedleToolset.callsToActOn(
            answer(toolCalls: [], withheldToolCalls: [reminderCall], confidence: 0.1),
            toolset: .organizer,
            normalizedRequest: "remind me to call mom"
        )

        #expect(callsToActOn == [reminderCall])
    }

    @Test func aReminderForSomethingTheUserNeverSaidIsNotAdded() {
        let reminderCall = DottieNeedleEngine.ToolCall(name: "add_reminder", arguments: ["task": "buy milk"])

        let callsToActOn = DottieNeedleToolset.callsToActOn(
            answer(toolCalls: [reminderCall]),
            toolset: .organizer,
            normalizedRequest: "remind me to call mom"
        )

        #expect(callsToActOn == nil)
    }

    @Test func calendarEventTitleMustMostlyComeFromTheUsersWords() {
        let saidEventCall = DottieNeedleEngine.ToolCall(name: "add_calendar_event", arguments: ["title": "Lunch with Sam", "when": "friday at noon"])
        let inventedEventCall = DottieNeedleEngine.ToolCall(name: "add_calendar_event", arguments: ["title": "Dentist appointment downtown", "when": "friday at noon"])
        let normalizedRequest = "add lunch with sam to my calendar friday at noon"

        #expect(DottieNeedleToolset.callsToActOn(answer(toolCalls: [saidEventCall]), toolset: .organizer, normalizedRequest: normalizedRequest) == [saidEventCall])
        #expect(DottieNeedleToolset.callsToActOn(answer(toolCalls: [inventedEventCall]), toolset: .organizer, normalizedRequest: normalizedRequest) == nil)
    }
}

struct NeedleInstantCommandWordsTests {

    private func instantCommandWords(_ name: String, _ arguments: [String: String]) -> String? {
        DottieNeedleToolset.instantCommandWords(for: DottieNeedleEngine.ToolCall(name: name, arguments: arguments))
    }

    @Test func appCallsBecomeOpenAndQuitWords() {
        #expect(instantCommandWords("open_app", ["name": " Safari "]) == "open safari")
        #expect(instantCommandWords("quit_app", ["name": "Slack"]) == "quit slack")
        #expect(instantCommandWords("open_app", ["name": "  "]) == nil)
    }

    @Test func windowMovesNameTheAppOrTheWindowInFront() {
        #expect(instantCommandWords("move_window", ["app": "Chrome", "place": "left"]) == "put chrome on the left")
        #expect(instantCommandWords("move_window", ["place": "other screen"]) == "put this window on my other screen")
        #expect(instantCommandWords("move_window", ["place": "upside down"]) == nil)
    }

    @Test func musicAndVolumeCallsBecomeTheirCommandWords() {
        #expect(instantCommandWords("control_music", ["action": "next"]) == "next song")
        #expect(instantCommandWords("change_volume", ["action": "down"]) == "volume down")
        #expect(instantCommandWords("change_volume", ["action": "set", "percent": "40"]) == "set the volume to 40")
    }

    @Test func volumePercentOutsideZeroToOneHundredIsRefused() {
        #expect(instantCommandWords("change_volume", ["action": "set", "percent": "140"]) == nil)
        #expect(instantCommandWords("change_volume", ["action": "set"]) == nil)
    }

    @Test func searchCallsNameTheirSite() {
        #expect(instantCommandWords("search_web", ["query": "Red Pandas", "site": "youtube"]) == "search youtube for red pandas")
        #expect(instantCommandWords("search_web", ["query": "red pandas", "site": "google"]) == "google red pandas")
    }

    @Test func unknownCallsHaveNoCommandWords() {
        #expect(instantCommandWords("launch_rocket", ["name": "safari"]) == nil)
    }
}

struct NeedleDateReadingTests {

    /// 2:00 in the afternoon on January 15, 2026, in the Mac's own time zone.
    private var afternoonMoment: Date {
        var dateComponents = DateComponents()
        dateComponents.year = 2026
        dateComponents.month = 1
        dateComponents.day = 15
        dateComponents.hour = 14
        dateComponents.minute = 0
        return Calendar.current.date(from: dateComponents) ?? Date(timeIntervalSince1970: 0)
    }

    @Test func minutesAndHoursFromNowAreRead() {
        let now = afternoonMoment

        #expect(DottieNeedleToolset.relativeDate(in: "remind me in 20 minutes", now: now) == now.addingTimeInterval(20 * 60))
        #expect(DottieNeedleToolset.relativeDate(in: "in an hour", now: now) == now.addingTimeInterval(60 * 60))
        #expect(DottieNeedleToolset.relativeDate(in: "In 2 hours", now: now) == now.addingTimeInterval(2 * 60 * 60))
        #expect(DottieNeedleToolset.relativeDate(in: "in half an hour", now: now) == now.addingTimeInterval(30 * 60))
        #expect(DottieNeedleToolset.relativeDate(in: "in forty five minutes", now: now) == now.addingTimeInterval(45 * 60))
    }

    @Test func textWithoutAnAmountOfTimeIsNotARelativeDate() {
        let now = afternoonMoment

        #expect(DottieNeedleToolset.relativeDate(in: "remind me to call mom", now: now) == nil)
        #expect(DottieNeedleToolset.relativeDate(in: "in 0 minutes", now: now) == nil)
    }

    @Test func datesAreWrittenInTheLocalFormTheToolsRead() {
        let now = afternoonMoment

        #expect(DottieNeedleToolset.isoLocalText(for: now, includesTime: true) == "2026-01-15T14:00")
        #expect(DottieNeedleToolset.isoLocalText(for: now, includesTime: false) == "2026-01-15")
    }

    @Test func reminderWithoutATimeHasNoDueDate() {
        let reminderCall = DottieNeedleEngine.ToolCall(name: "add_reminder", arguments: ["task": "call mom"])

        let organizerStep = DottieNeedleToolset.organizerStep(for: reminderCall, fullRequest: "remind me to call mom", now: afternoonMoment)

        #expect(organizerStep?.functionName == "add_reminder")
        #expect(organizerStep?.arguments == ["title": "call mom"])
    }

    @Test func reminderInTwentyMinutesIsDueTwentyMinutesFromNow() {
        let reminderCall = DottieNeedleEngine.ToolCall(name: "add_reminder", arguments: ["task": "call mom", "when": "in 20 minutes"])

        let organizerStep = DottieNeedleToolset.organizerStep(for: reminderCall, fullRequest: "remind me to call mom in 20 minutes", now: afternoonMoment)

        #expect(organizerStep?.arguments == ["title": "call mom", "due": "2026-01-15T14:20"])
    }

    @Test func calendarEventWithNoReadableTimeIsNotAdded() {
        let eventCall = DottieNeedleEngine.ToolCall(name: "add_calendar_event", arguments: ["title": "team sync", "when": ""])

        let organizerStep = DottieNeedleToolset.organizerStep(for: eventCall, fullRequest: "put team sync on my calendar", now: afternoonMoment)

        #expect(organizerStep == nil)
    }

    @Test func calendarEventKeepsItsPlace() {
        let eventCall = DottieNeedleEngine.ToolCall(name: "add_calendar_event", arguments: ["title": "lunch with sam", "when": "in an hour", "place": "the diner"])

        let organizerStep = DottieNeedleToolset.organizerStep(for: eventCall, fullRequest: "add lunch with sam in an hour at the diner", now: afternoonMoment)

        #expect(organizerStep?.functionName == "add_calendar_event")
        #expect(organizerStep?.arguments == ["title": "lunch with sam", "start": "2026-01-15T15:00", "location": "the diner"])
    }
}

struct NeedleMeaningVectorTests {

    @Test func centerIsTheAverageOfTheReferenceVectors() {
        #expect(DottieNeedleMeaning.centerVector(of: [[1, 2], [3, 4]]) == [2, 3])
    }

    @Test func noReferenceVectorsMeansNoCenter() {
        #expect(DottieNeedleMeaning.centerVector(of: []) == nil)
        #expect(DottieNeedleMeaning.centerVector(of: [[]]) == nil)
    }

    @Test func centeredVectorIsBroughtBackToUnitLength() {
        #expect(DottieNeedleMeaning.centered([4, 1], center: [1, 1]) == [1, 0])
    }

    @Test func vectorOfAnotherSizeIsLeftAsItIs() {
        #expect(DottieNeedleMeaning.centered([1, 2, 3], center: [1, 1]) == [1, 2, 3])
    }
}
