//
//  DictationTextTests.swift
//  leanring-buddyTests
//
//  Dictation on the Mac: the user's learned fixes swapped into what Apple's
//  recognizer heard, whole words only, whatever the case.
//

import Foundation
import Testing
@testable import Dottie

struct DictationTextTests {
    @Test func learnedFixReplacesTheHeardWord() {
        let fixed = DictationText.applyingCorrections(to: "tell wasi I'm late", corrections: [(heard: "Wasi", meant: "Waseem")])
        #expect(fixed == "tell Waseem I'm late")
    }

    @Test func onlyWholeWordsAreFixed() {
        let fixed = DictationText.applyingCorrections(to: "the wasing machine", corrections: [(heard: "wasi", meant: "Waseem")])
        #expect(fixed == "the wasing machine")
    }

    @Test func phrasesAndPunctuationNextToThemWork() {
        let fixed = DictationText.applyingCorrections(to: "open dotty, then dotty.", corrections: [(heard: "dotty", meant: "Dottie")])
        #expect(fixed == "open Dottie, then Dottie.")
    }

    @Test func specialCharactersInAFixAreTakenLiterally() {
        let fixed = DictationText.applyingCorrections(to: "email c plus plus team", corrections: [(heard: "c plus plus", meant: "C++ $1")])
        #expect(fixed == "email C++ $1 team")
    }

    @Test func noFixesLeavesTheTextAlone() {
        #expect(DictationText.applyingCorrections(to: "hello", corrections: []) == "hello")
        #expect(DictationText.applyingCorrections(to: "hello", corrections: [(heard: "", meant: "x")]) == "hello")
    }
}
