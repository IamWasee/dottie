//
//  KokoroSpeakerTests.swift
//  leanring-buddyTests
//
//  Until Kokoro has loaded, classic mode must use the Mac's own voice
//  instead of waiting silently for the download.
//

import Testing
@testable import Dottie

@MainActor
struct KokoroSpeakerTests {

    @Test func aFreshSpeakerIsNotReadySoTheSystemVoiceAnswers() {
        let freshSpeaker = DottieKokoroSpeaker()
        #expect(freshSpeaker.isReady == false)
        #expect(freshSpeaker.isPlaying == false)
    }

    @Test func stoppingBeforeAnythingPlayedIsHarmless() {
        let freshSpeaker = DottieKokoroSpeaker()
        freshSpeaker.stop()
        #expect(freshSpeaker.playingVoiceName == nil)
    }
}
