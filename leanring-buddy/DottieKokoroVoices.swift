//
//  DottieKokoroVoices.swift
//  leanring-buddy
//
//  Dottie's on-Mac voices: the five Kokoro voices celly kept (Jarvis,
//  Butler, Heart, Bella, Emma), each a Kokoro voice pack and a speaking
//  speed, and which one is picked. Foundation only, so it can be unit tested.
//

import Foundation

struct DottieKokoroVoice: Identifiable, Equatable {
    /// The name the user sees and picks.
    let name: String
    /// How it sounds, in a couple of words.
    let sound: String
    /// The Kokoro voice pack it speaks with.
    let kokoroVoiceID: String
    /// 1 is Kokoro's normal pace.
    let speed: Float
    var id: String { name }
}

enum DottieKokoroVoices {
    static let chosenVoiceDefaultsKey = "DottieKokoroVoiceName"

    /// Jarvis and Butler were mixes of British voices in the samples celly
    /// kept; one pack each here (the on-Mac engine speaks one pack at a time),
    /// the pack that carried most of the mix.
    static let all: [DottieKokoroVoice] = [
        DottieKokoroVoice(name: "Heart", sound: "Warm", kokoroVoiceID: "af_heart", speed: 1.05),
        DottieKokoroVoice(name: "Bella", sound: "Bright", kokoroVoiceID: "af_bella", speed: 1.05),
        DottieKokoroVoice(name: "Emma", sound: "British, calm", kokoroVoiceID: "bf_emma", speed: 1.0),
        DottieKokoroVoice(name: "Jarvis", sound: "British, smooth", kokoroVoiceID: "bm_daniel", speed: 0.95),
        DottieKokoroVoice(name: "Butler", sound: "British, deep", kokoroVoiceID: "bm_fable", speed: 0.95)
    ]

    static let defaultVoice = all[0]

    /// The voice with this name (any case), or the default one.
    static func voice(named voiceName: String?) -> DottieKokoroVoice {
        guard let voiceName else { return defaultVoice }
        let wantedName = voiceName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.first { $0.name.lowercased() == wantedName } ?? defaultVoice
    }

    static func chosenVoice(in defaults: UserDefaults = .standard) -> DottieKokoroVoice {
        voice(named: defaults.string(forKey: chosenVoiceDefaultsKey))
    }

    static func choose(_ voiceName: String, in defaults: UserDefaults = .standard) {
        defaults.set(voice(named: voiceName).name, forKey: chosenVoiceDefaultsKey)
    }

    /// Text worth handing to Kokoro: trimmed, and nil when there's nothing to say.
    static func speakableText(_ text: String) -> String? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedText.isEmpty ? nil : trimmedText
    }
}
