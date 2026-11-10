//
//  RoutineAndStreamParsingTests.swift
//  leanring-buddyTests
//
//  Unit tests for two pieces of pure text handling that everything else
//  leans on: the <ROUTINE> blocks a helper ends its reply with, and the
//  server-sent events the Worker streams Gemini's answers as.
//

import Foundation
import Testing
@testable import Dottie

struct RoutineBlockParsingTests {

    @Test func replyWithoutABlockIsLeftAlone() {
        let extraction = ClickyRoutinePrompts.extractRoutineActions(from: "Here are today's issues.")

        #expect(extraction.replyWithoutBlocks == "Here are today's issues.")
        #expect(extraction.routineActions.isEmpty)
    }

    @Test func createBlockIsParsedAndRemovedFromTheReply() {
        let replyText = """
        I'll check this every hour.

        <ROUTINE>{"action":"create","every_minutes":60,"title":"Repo Issues","task":"Check for new issues","watch_url":"https://example.com/status"}</ROUTINE>
        """

        let extraction = ClickyRoutinePrompts.extractRoutineActions(from: replyText)

        #expect(extraction.replyWithoutBlocks == "I'll check this every hour.")
        #expect(extraction.routineActions.count == 1)
        let createAction = extraction.routineActions.first
        #expect(createAction?.action == .create)
        #expect(createAction?.title == "Repo Issues")
        #expect(createAction?.task == "Check for new issues")
        #expect(createAction?.everyMinutes == 60)
        #expect(createAction?.watchURL == "https://example.com/status")
        #expect(createAction?.newTitle == nil)
    }

    @Test func severalBlocksAreAllParsedInOrder() {
        let replyText = """
        Done. <ROUTINE>{"action":"pause","title":"Repo Issues"}</ROUTINE> And renamed the other one.
        <ROUTINE>{"action":"update","title":"Prices","new_title":"Laptop Prices"}</ROUTINE>
        """

        let extraction = ClickyRoutinePrompts.extractRoutineActions(from: replyText)

        #expect(extraction.routineActions.map(\.action) == [.pause, .update])
        #expect(extraction.routineActions.last?.newTitle == "Laptop Prices")
        #expect(!extraction.replyWithoutBlocks.contains("<ROUTINE>"))
        #expect(!extraction.replyWithoutBlocks.contains("</ROUTINE>"))
        #expect(extraction.replyWithoutBlocks.hasPrefix("Done."))
    }

    @Test func blockThatIsNotValidJSONIsRemovedButNotActedOn() {
        let replyText = "All set. <ROUTINE>{this is not json}</ROUTINE>"

        let extraction = ClickyRoutinePrompts.extractRoutineActions(from: replyText)

        #expect(extraction.replyWithoutBlocks == "All set.")
        #expect(extraction.routineActions.isEmpty)
    }

    @Test func blockWithAnUnknownActionIsNotActedOn() {
        let replyText = "<ROUTINE>{\"action\":\"explode\",\"title\":\"Repo Issues\"}</ROUTINE>"

        let extraction = ClickyRoutinePrompts.extractRoutineActions(from: replyText)

        #expect(extraction.replyWithoutBlocks.isEmpty)
        #expect(extraction.routineActions.isEmpty)
    }

    @Test func openingTagWithoutAClosingTagStaysInTheReply() {
        let replyText = "Working on it <ROUTINE>{\"action\":\"create\""

        let extraction = ClickyRoutinePrompts.extractRoutineActions(from: replyText)

        #expect(extraction.replyWithoutBlocks == replyText)
        #expect(extraction.routineActions.isEmpty)
    }
}

struct RoutineQuietReplyTests {

    @Test func exactMarkerCountsAsNothingNew() {
        #expect(ClickyRoutinePrompts.isNothingNewReply("NOTHING NEW"))
    }

    @Test func markerInAnyLetterCaseWithSpacesAroundCounts() {
        #expect(ClickyRoutinePrompts.isNothingNewReply("  nothing new.\n"))
    }

    @Test func realReportDoesNotCountAsNothingNew() {
        #expect(!ClickyRoutinePrompts.isNothingNewReply("Two new issues were opened today."))
    }

    @Test func longReplyThatOnlyStartsWithTheMarkerIsStillShown() {
        let longReply = "NOTHING NEW " + String(repeating: "but here is a long story ", count: 20)

        #expect(longReply.count > 200)
        #expect(!ClickyRoutinePrompts.isNothingNewReply(longReply))
    }
}

struct RoutineCadenceDescriptionTests {

    @Test func commonCadencesReadNaturally() {
        #expect(ClickyRoutine.cadenceDescription(everyMinutes: 60) == "every hour")
        #expect(ClickyRoutine.cadenceDescription(everyMinutes: 1440) == "every day")
        #expect(ClickyRoutine.cadenceDescription(everyMinutes: 10080) == "every week")
    }

    @Test func wholeDaysAndHoursAreCounted() {
        #expect(ClickyRoutine.cadenceDescription(everyMinutes: 2880) == "every 2 days")
        #expect(ClickyRoutine.cadenceDescription(everyMinutes: 180) == "every 3 hours")
    }

    @Test func everythingElseIsSaidInMinutes() {
        #expect(ClickyRoutine.cadenceDescription(everyMinutes: 45) == "every 45 minutes")
        #expect(ClickyRoutine.cadenceDescription(everyMinutes: 90) == "every 90 minutes")
    }
}

struct GeminiServerSentEventsTests {

    /// One event line the way the Worker sends it.
    private func eventLine(text: String, isThought: Bool = false) -> String {
        let thoughtField = isThought ? ",\"thought\":true" : ""
        return "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"\(text)\"\(thoughtField)}]}}]}"
    }

    @Test func textIsJoinedAcrossEventsSeparatedByCarriageReturnLineFeed() {
        // The bug this file was written for: "\r\n" is one Character in
        // Swift, so splitting on "\n" found nothing and answers were empty.
        let responseText = eventLine(text: "Hello, ") + "\r\n\r\n" + eventLine(text: "world") + "\r\n\r\n"

        let answerText = GeminiServerSentEvents.text(from: Data(responseText.utf8))

        #expect(answerText == "Hello, world")
    }

    @Test func textIsJoinedAcrossEventsSeparatedByPlainLineFeeds() {
        let responseText = eventLine(text: "One ") + "\n\n" + eventLine(text: "two")

        let answerText = GeminiServerSentEvents.text(from: Data(responseText.utf8))

        #expect(answerText == "One two")
    }

    @Test func thinkingPartsAreLeftOutOfTheTextButKeptInTheParts() {
        let responseText = eventLine(text: "Let me think", isThought: true) + "\n" + eventLine(text: "The answer is 4")
        let responseData = Data(responseText.utf8)

        #expect(GeminiServerSentEvents.text(from: responseData) == "The answer is 4")
        #expect(GeminiServerSentEvents.parts(from: responseData).count == 2)
    }

    @Test func functionCallPartsKeepTheirFields() {
        let responseText = "data: {\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{\"name\":\"open_url\",\"args\":{\"url\":\"https://example.com\"}},\"thoughtSignature\":\"abc\"}]}}]}"

        let allParts = GeminiServerSentEvents.parts(from: Data(responseText.utf8))

        #expect(allParts.count == 1)
        let functionCall = allParts.first?["functionCall"] as? [String: Any]
        #expect(functionCall?["name"] as? String == "open_url")
        #expect(allParts.first?["thoughtSignature"] as? String == "abc")
    }

    @Test func linesThatAreNotEventsOrNotJSONAreSkipped() {
        let responseText = [
            ": keep-alive comment",
            "event: message",
            "data: not json at all",
            "data: {\"candidates\":[]}",
            eventLine(text: "still here"),
        ].joined(separator: "\n")

        let answerText = GeminiServerSentEvents.text(from: Data(responseText.utf8))

        #expect(answerText == "still here")
    }

    @Test func emptyResponseGivesEmptyText() {
        #expect(GeminiServerSentEvents.text(from: Data()) == "")
        #expect(GeminiServerSentEvents.parts(from: Data()).isEmpty)
    }
}
