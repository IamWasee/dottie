//
//  DottieGameResearch.swift
//  leanring-buddy
//
//  Before playing, Dottie works out which game it is and reads up on it,
//  the way a person looks a game up before trying it:
//
//  - Naming: the app's window often says only "Roblox", so the game's
//    name comes from what the user asked ("build a golem roblox"), the
//    window and the text on screen. A game Dottie already has a notebook
//    for keeps that exact name, so it always gets the same notebook and
//    3D map.
//  - Guide: a web search for the game (the Worker's /search route), turned
//    into a short guide for the game brain: what the game is, the goal,
//    how to make progress, the controls and what to avoid. Kept in the
//    notebook and looked up again after two weeks, since games update.
//

import Foundation

@MainActor
enum DottieGameResearch {
    private static let namingModel = "gemini-3.5-flash-lite"
    private static let guideModel = "gemini-3.6-flash"
    static let secondsBeforeGuideIsLookedUpAgain = 14.0 * 24 * 60 * 60

    /// The game's name, like "Build a Golem (Roblox)", or the window's
    /// name when it can't be told.
    static func identifyGame(taskText: String, windowGameName: String, screenText: [String]) async -> String {
        let knownGameNames = DottieGameNotebook.savedGameNames()
        let knownGamesLine = knownGameNames.isEmpty ? "none" : knownGameNames.joined(separator: "; ")
        let prompt = """
        Which video game is the user playing?
        What the user asked: "\(taskText)"
        The game's window: "\(windowGameName)"
        Text on the screen: \(screenText.prefix(30).joined(separator: " | "))
        Games already played before: \(knownGamesLine)

        Answer with the game's name only, nothing else.
        - If it's one of the games already played before, answer that name exactly as written there.
        - For a game inside a platform (a Roblox experience, a Fortnite island, a Minecraft server), answer "<the game's own name> (<platform>)", like "Build a Golem (Roblox)".
        - If you can't tell, answer "\(windowGameName)".
        """
        guard let answer = await DottieChat.ask(prompt, model: namingModel) else { return windowGameName }
        let firstLine = answer.split(separator: "\n").first.map(String.init) ?? ""
        let cleanedName = String(firstLine
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'*`. ").union(.whitespacesAndNewlines))
            .prefix(80))
        guard !cleanedName.isEmpty else { return windowGameName }
        return knownGameNames.first { $0.caseInsensitiveCompare(cleanedName) == .orderedSame } ?? cleanedName
    }

    /// A short guide to the game from the web, or nil when nothing useful
    /// was found.
    static func writeGuide(gameName: String) async -> String? {
        async let guideResults = DottieWebSearch.search("\(gameName) beginner guide how to play")
        async let wikiResults = DottieWebSearch.search("\(gameName) wiki")
        let allResults = [await guideResults, await wikiResults]
            // A failed search says so in a sentence instead of results.
            .filter { $0.hasPrefix("web results") }
        guard !allResults.isEmpty else { return nil }

        let prompt = """
        An AI is about to play the video game "\(gameName)" by watching the screen and pressing keys. Using only the web results below, write it a guide.

        Sections, each short:
        What it is: one or two lines.
        The goal: what winning or progress means.
        How to progress: the core loop and the first five things to do in a new game, in order.
        Controls: keys and buttons, if the results say.
        Tips: what to do and what to avoid (dangers, common mistakes).

        Under 250 words, plain text. Write "unknown" where the results don't say. If the results aren't about this game, answer exactly: NOT FOUND

        \(allResults.joined(separator: "\n\n"))
        """
        guard let guideText = await DottieChat.ask(prompt, model: guideModel),
              !guideText.isEmpty,
              !guideText.uppercased().hasPrefix("NOT FOUND") else { return nil }
        return String(guideText.prefix(2500))
    }
}
