//
//  KokoroVoicesTests.swift
//  leanring-buddyTests
//
//  Dottie's on-Mac Kokoro voices: the five kept voices, picking one by
//  name, remembering the pick, and what text is worth speaking.
//

import Foundation
import Testing
@testable import Dottie

struct KokoroVoicesTests {
    private func freshDefaults() -> UserDefaults {
        let suiteName = "KokoroVoicesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func offersTheFiveKeptVoicesWithUniqueNames() {
        let names = DottieKokoroVoices.all.map(\.name)
        #expect(names == ["Heart", "Bella", "Emma", "Jarvis", "Butler"])
        #expect(Set(names).count == names.count)
    }

    @Test func everyVoiceUsesARealKokoroPackAndASensibleSpeed() {
        // The English packs FluidAudio publishes that these voices use.
        let publishedPacks: Set<String> = ["af_heart", "af_bella", "bf_emma", "bm_daniel", "bm_fable"]
        for voice in DottieKokoroVoices.all {
            #expect(publishedPacks.contains(voice.kokoroVoiceID), "\(voice.name) uses \(voice.kokoroVoiceID)")
            #expect(voice.speed >= 0.8 && voice.speed <= 1.2)
            #expect(!voice.sound.isEmpty)
        }
    }

    @Test func findsAVoiceByNameIgnoringCaseAndSpaces() {
        #expect(DottieKokoroVoices.voice(named: "jarvis").kokoroVoiceID == "bm_daniel")
        #expect(DottieKokoroVoices.voice(named: "  BUTLER ").kokoroVoiceID == "bm_fable")
    }

    @Test func fallsBackToHeartForAnUnknownOrMissingName() {
        #expect(DottieKokoroVoices.voice(named: "Kore") == DottieKokoroVoices.defaultVoice)
        #expect(DottieKokoroVoices.voice(named: nil).name == "Heart")
        #expect(DottieKokoroVoices.voice(named: "").name == "Heart")
    }

    @Test func remembersTheChosenVoice() {
        let defaults = freshDefaults()
        #expect(DottieKokoroVoices.chosenVoice(in: defaults).name == "Heart")
        DottieKokoroVoices.choose("emma", in: defaults)
        #expect(defaults.string(forKey: DottieKokoroVoices.chosenVoiceDefaultsKey) == "Emma")
        #expect(DottieKokoroVoices.chosenVoice(in: defaults).name == "Emma")
    }

    @Test func choosingAnUnknownNameSavesTheDefault() {
        let defaults = freshDefaults()
        DottieKokoroVoices.choose("Nobody", in: defaults)
        #expect(DottieKokoroVoices.chosenVoice(in: defaults).name == "Heart")
    }

    @Test func speaksOnlyTextWithWordsInIt() {
        #expect(DottieKokoroVoices.speakableText("  Hello there.\n") == "Hello there.")
        #expect(DottieKokoroVoices.speakableText("   \n\t") == nil)
        #expect(DottieKokoroVoices.speakableText("") == nil)
    }

    /// The path an answer takes in classic mode: the saved pick becomes the
    /// pack and speed handed to Kokoro, with the text trimmed.
    @Test func aClassicAnswerGetsThePickedPackAndTrimmedText() {
        let defaults = freshDefaults()
        DottieKokoroVoices.choose("Jarvis", in: defaults)
        let voice = DottieKokoroVoices.chosenVoice(in: defaults)
        #expect(voice.kokoroVoiceID == "bm_daniel")
        #expect(voice.speed == 0.95)
        #expect(DottieKokoroVoices.speakableText(" Your meeting starts at three. ") == "Your meeting starts at three.")
    }
}
