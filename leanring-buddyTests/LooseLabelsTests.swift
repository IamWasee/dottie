//
//  LooseLabelsTests.swift
//  leanring-buddyTests
//
//  Finding a remembered button again when its words changed a little:
//  counts, numbers, dates and times left out, a few extra words allowed,
//  other kinds of control and far-away matches refused, the nearest of
//  equals picked.
//

import Foundation
import Testing
@testable import Dottie

@MainActor
struct LooseLabelsTests {
    private typealias Loose = DottieLooseLabels

    @Test func countsNumbersAndDatesAreLeftOut() {
        #expect(Loose.coreWords("Inbox (3)") == ["inbox"])
        #expect(Loose.coreWords("Updated 5 min ago") == ["updated"])
        #expect(Loose.coreWords("Nov 27 report") == ["report"])
        #expect(Loose.coreWords("Q3 Sales [draft]") == ["sales"])
    }

    @Test func labelsThatOnlyChangedTheirCountAreTheSame() {
        #expect(Loose.similarity("Inbox (3)", "Inbox (12)") == 1)
        #expect(Loose.similarity("Updated 2 min ago", "Updated 5 min ago") == 1)
        #expect(Loose.similarity("Nov 26 report", "Nov 27 report") == 1)
    }

    @Test func aFewExtraWordsStillMatch() {
        #expect(Loose.similarity("Rename", "Rename column") >= Loose.sameControlScore)
        #expect(Loose.similarity("New query", "Create new query") >= Loose.sameControlScore)
    }

    @Test func differentControlsDoNotMatch() {
        #expect(Loose.similarity("Rename column", "Delete column") < Loose.sameControlScore)
        #expect(Loose.similarity("Save", "Share") == 0)
        #expect(Loose.similarity("", "Save") == 0)
    }

    @Test func numberOnlyLabelsMatchOnlyWhenTheyReadTheSame() {
        #expect(Loose.similarity("42", "42") == 1)
        #expect(Loose.similarity("42", "43") == 0)
    }

    @Test func theBestMatchIsAlikeOfTheSameKindAndNear() {
        let candidates = [
            Loose.Candidate(label: "Rename column", role: "link", centerX: 500, centerY: 500),
            Loose.Candidate(label: "Rename column", role: "button", centerX: 110, centerY: 210),
            Loose.Candidate(label: "Rename column", role: nil, centerX: 900, centerY: 900)
        ]
        let match = Loose.bestMatch(forLabel: "Rename column", role: "button", centerX: 100, centerY: 200, among: candidates)
        #expect(match?.role == "button")
    }

    @Test func aMatchFarFromWhereItWasIsRefused() {
        let candidates = [Loose.Candidate(label: "Export", role: nil, centerX: 950, centerY: 950)]
        #expect(Loose.bestMatch(forLabel: "Export", role: nil, centerX: 50, centerY: 50, among: candidates) == nil)
        #expect(Loose.bestMatch(forLabel: "Export", role: nil, centerX: nil, centerY: nil, among: candidates) != nil)
    }

    @Test func textReadOffTheScreenCanBeANamedControl() {
        let candidates = [Loose.Candidate(label: "Inbox (5)", role: nil, centerX: 100, centerY: 100)]
        let match = Loose.bestMatch(forLabel: "Inbox (2)", role: "button", centerX: 100, centerY: 110, among: candidates)
        #expect(match?.label == "Inbox (5)")
    }

    @Test func readingExactlyTheSameBeatsBeingNearer() {
        let candidates = [
            Loose.Candidate(label: "Invoice 1044", role: nil, centerX: 100, centerY: 200),
            Loose.Candidate(label: "Invoice 1043", role: nil, centerX: 100, centerY: 260)
        ]
        let match = Loose.bestMatch(forLabel: "Invoice 1043", role: nil, centerX: 100, centerY: 200, among: candidates)
        #expect(match?.label == "Invoice 1043")
    }
}
