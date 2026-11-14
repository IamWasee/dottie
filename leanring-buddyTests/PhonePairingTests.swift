//
//  PhonePairingTests.swift
//  leanring-buddyTests
//
//  Unit tests for the name shown when a Telegram chat asks to pair with
//  Dottie (DottiePhoneBridge.pairingSenderName). The user decides from this
//  name whether the phone is theirs, so it has to say who is really asking.
//

import Testing
@testable import Dottie

@MainActor
struct PhonePairingTests {

    @Test func aFullNameAndUsernameAreBothShown() {
        let message: [String: Any] = ["from": ["first_name": "Sam", "last_name": "Lee", "username": "samlee"]]
        #expect(DottiePhoneBridge.pairingSenderName(fromMessage: message) == "Sam Lee (@samlee)")
    }

    @Test func aFirstNameAloneIsEnough() {
        let message: [String: Any] = ["from": ["first_name": "Sam"]]
        #expect(DottiePhoneBridge.pairingSenderName(fromMessage: message) == "Sam")
    }

    @Test func aUsernameAloneIsShownWithItsAtSign() {
        let message: [String: Any] = ["from": ["username": "samlee"]]
        #expect(DottiePhoneBridge.pairingSenderName(fromMessage: message) == "@samlee")
    }

    @Test func blankNamesAreLeftOut() {
        let message: [String: Any] = ["from": ["first_name": "  ", "last_name": "Lee", "username": ""]]
        #expect(DottiePhoneBridge.pairingSenderName(fromMessage: message) == "Lee")
    }

    @Test func aMessageWithNoSenderSaysSomeone() {
        #expect(DottiePhoneBridge.pairingSenderName(fromMessage: [:]) == "Someone")
        #expect(DottiePhoneBridge.pairingSenderName(fromMessage: ["from": "not a sender"]) == "Someone")
    }
}
