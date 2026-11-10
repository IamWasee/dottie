//
//  DottieLogTests.swift
//  leanring-buddyTests
//
//  Unit tests for DottieLog: the words written in the code always reach
//  the log, and the values put into a line are hidden unless details are
//  switched on.
//

import Testing
@testable import Dottie

struct DottieLogMessageTests {

    @Test func lineWithoutValuesIsTheSameWithAndWithoutDetails() {
        let message: DottieLogMessage = "Screen task stopped"

        #expect(message.textWithDetails == "Screen task stopped")
        #expect(message.textWithoutDetails == "Screen task stopped")
    }

    @Test func valuesAreHiddenButTheWordsAroundThemStay() {
        let spokenWords = "call mom at five"
        let message: DottieLogMessage = "Companion received transcript: \(spokenWords)"

        #expect(message.textWithDetails == "Companion received transcript: call mom at five")
        #expect(message.textWithoutDetails == "Companion received transcript: ‹…›")
        #expect(!message.textWithoutDetails.contains("mom"))
    }

    @Test func everyValueInALineIsHidden() {
        let stepNumber = 3
        let failureReason = "the button moved"
        let message: DottieLogMessage = "Step \(stepNumber) failed: \(failureReason)"

        #expect(message.textWithDetails == "Step 3 failed: the button moved")
        #expect(message.textWithoutDetails == "Step ‹…› failed: ‹…›")
    }

    @Test func valuesOfAnyKindCanBeLogged() {
        let optionalLabel: String? = nil
        let message: DottieLogMessage = "Pointing at \(optionalLabel ?? "element") (\(12.5), \(true))"

        #expect(message.textWithDetails == "Pointing at element (12.5, true)")
    }
}

struct DottieLogShownTextTests {

    @Test func detailsShowOnlyWhenSwitchedOn() {
        let helperName = "Research Dot"
        let message: DottieLogMessage = "Helper finished: \(helperName)"

        #expect(DottieLog.shownText(of: message, showsDetails: true) == "Helper finished: Research Dot")
        #expect(DottieLog.shownText(of: message, showsDetails: false) == "Helper finished: ‹…›")
    }

    @Test func categoryIsTheFileNameWithoutItsFolderOrEnding() {
        #expect(DottieLog.category(forCallerFile: "Dottie/DottieScreenTaskRunner.swift") == "DottieScreenTaskRunner")
        #expect(DottieLog.category(forCallerFile: "CompanionManager.swift") == "CompanionManager")
        #expect(DottieLog.category(forCallerFile: "SomethingElse") == "SomethingElse")
    }
}
