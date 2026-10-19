//
//  DottieOnDeviceModel.swift
//  leanring-buddy
//
//  Apple's on-device language model (Apple Intelligence, macOS 26 and
//  later), for small text jobs that don't need the screen or the internet:
//  a quick answer, or sorting a request ("is this a simple job?"). It
//  answers in well under a second, costs nothing and works offline, so it
//  saves a trip to Gemini where it can.
//
//  Everything here quietly returns nil when the model isn't there (older
//  macOS, a Mac without Apple Intelligence, the model still downloading,
//  or a build made without the macOS 26 SDK), and callers carry on as
//  before. Voice stays on Gemini Live.
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum DottieOnDeviceModel {
    /// Classifying has to be quick to be worth it; past this, give up.
    static let classifyTimeoutSeconds: Double = 1.5
    static let answerTimeoutSeconds: Double = 8

    /// True when the model can answer right now.
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// Why it can't answer, in plain words, or nil when it can.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return "This Mac can't run Apple Intelligence."
                case .appleIntelligenceNotEnabled:
                    return "Apple Intelligence is off. Turn it on in System Settings → Apple Intelligence & Siri."
                case .modelNotReady:
                    return "Apple's model is still downloading. It will be ready on its own."
                @unknown default:
                    return "Apple's model isn't available right now."
                }
            }
        }
        return "Needs macOS 26 or later."
        #else
        return "This copy of Dottie was built without Apple's on-device model."
        #endif
    }

    /// One answer from the on-device model, or nil when it isn't available
    /// or takes too long.
    static func respond(instructions: String, prompt: String, maximumTokens: Int = 300, timeoutSeconds: Double = answerTimeoutSeconds) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard isAvailable else { return nil }
            return await withTimeout(seconds: timeoutSeconds) {
                let session = LanguageModelSession(instructions: instructions)
                let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: maximumTokens)
                guard let response = try? await session.respond(to: prompt, options: options) else { return nil }
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }
        }
        #endif
        return nil
    }

    /// Sorts `text` into one of `labels` (lowercase single words), or nil
    /// when the model isn't available, is slow, or answers something else.
    static func classify(_ text: String, labels: [String], instructions: String) async -> String? {
        guard isAvailable, !labels.isEmpty else { return nil }
        guard let answer = await respond(
            instructions: instructions,
            prompt: "Request: \(text.prefix(1500))\nAnswer with one word: \(labels.joined(separator: " or ")).",
            maximumTokens: 8,
            timeoutSeconds: classifyTimeoutSeconds
        ) else { return nil }
        let answerWords = answer.lowercased().components(separatedBy: CharacterSet.letters.inverted)
        return labels.first { answerWords.contains($0) }
    }

    /// A quick answer to a plain text question that doesn't need the screen,
    /// the web or the user's files ("how many ounces in a cup", "say thanks
    /// in Spanish"), or nil when it needs Gemini. For a type-to-ask bar.
    static func quickAnswer(_ question: String) async -> String? {
        guard isAvailable else { return nil }
        let kind = await classify(
            question,
            labels: ["simple", "needs"],
            instructions: """
            You decide if a question to a Mac assistant can be answered from general knowledge alone. \
            "simple" means a short, stable, general-knowledge answer, a tiny rewrite, a translation or \
            arithmetic. "needs" means it needs the screen ("this", "here", "on my screen"), today's news, \
            weather, prices, the user's own files, mail or calendar, or doing something on the Mac. \
            Answer with one word: simple or needs.
            """
        )
        guard kind == "simple" else { return nil }
        return await respond(
            instructions: "You are Dottie, a friendly Mac companion. Answer in one or two short, plain sentences. No markdown.",
            prompt: question,
            maximumTokens: 200
        )
    }

    private static func withTimeout(seconds: Double, operation: @escaping @Sendable () async -> String?) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let firstResult = await group.next() ?? nil
            group.cancelAll()
            return firstResult
        }
    }
}
