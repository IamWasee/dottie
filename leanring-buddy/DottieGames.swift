//
//  DottieGames.swift
//  leanring-buddy
//
//  Games with Dottie, through one voice tool, `game`:
//  - trivia: a round of 5 questions on any category and difficulty, made
//    with one quick Gemini call (JSON), checked on the Mac.
//  - 20 questions: Dottie guesses what the user thinks of, or the user
//    guesses what Dottie picked (picked on the Mac, no call).
//  - guess my drawing: the user doodles on a drawing pad over the screen
//    (or draws in any app and asks), and one Gemini call looks at it; Dottie
//    says her guesses out loud.
//  - word chain: each word starts with the last letter of the one before,
//    no repeats, checked on the Mac.
//  Points and wins feed Dottie's levels (DottieLevels).
//

import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class DottieGames {
    static let shared = DottieGames()

    struct TriviaQuestion {
        let question: String
        var choices: [String]
        let answer: String
        let funFact: String
    }

    enum Game {
        case trivia(category: String, questions: [TriviaQuestion], index: Int, score: Int, hintsUsed: Int)
        case twentyQuestions(dottieGuesses: Bool, secret: String?, questionCount: Int)
        case drawing
        case wordChain(usedWords: [String], nextLetter: Character, score: Int, lives: Int, waitingForDottie: Bool)
    }

    private(set) var current: Game?
    private static let fastModel = "gemini-3.5-flash-lite"
    private var drawingPad: DottieDrawingPadWindowController?

    private init() {}

    // MARK: - Starting

    func start(game gameName: String, category: String?, difficulty: String?, dottieGuesses: Bool, onScreen: Bool) async -> String {
        finishSilently()
        switch gameName {
        case "trivia":
            return await startTrivia(category: category ?? "general knowledge", difficulty: difficulty ?? "medium")
        case "twenty_questions":
            if dottieGuesses {
                current = .twentyQuestions(dottieGuesses: true, secret: nil, questionCount: 0)
                return "20 questions, you guess. ask the user to think of something (an animal, object, person or place) and say when ready. then ask one yes/no question at a time; after each reply call game answer with their reply. when you make a guess and they say it's right, call game answer with correct true."
            }
            let secret = Self.twentyQuestionsSecrets.randomElement() ?? "a penguin"
            current = .twentyQuestions(dottieGuesses: false, secret: secret, questionCount: 0)
            return "20 questions, the user guesses. your secret is \"\(secret)\": never say it unless they guess it or give up. tell them you've thought of something and they get 20 yes/no questions. answer each question honestly with yes, no or sort of, plus a tiny playful nudge. pass every question or guess to game answer so it's counted and checked."
        case "drawing":
            current = .drawing
            if onScreen {
                return await guessDrawing(fromScreen: true)
            }
            openDrawingPad()
            return "guess my drawing: a drawing pad is open over the screen. tell the user to draw anything with the mouse and click Guess when done; your guesses come to you then. say that in a few playful words."
        case "word_chain":
            let firstWord = Self.wordChainStarters.randomElement() ?? "apple"
            let nextLetter = firstWord.last ?? "e"
            current = .wordChain(usedWords: [firstWord], nextLetter: nextLetter, score: 0, lives: 3, waitingForDottie: false)
            return "word chain! you go first with \"\(firstWord)\". the user needs a word starting with \"\(nextLetter)\". no repeats; they have 3 lives and win at 10 words. pass each of their words to game answer."
        default:
            return "games: trivia, twenty_questions, drawing or word_chain."
        }
    }

    private func startTrivia(category: String, difficulty: String) async -> String {
        let prompt = """
        write 5 \(difficulty) trivia questions about \(category) for a fun voice quiz. each has 4 short choices and exactly one right answer; vary which choice is right. questions short enough to read aloud. family friendly, facts you're sure of.
        reply with only a JSON array: [{"question": "...", "choices": ["...","...","...","..."], "answer": "the exact right choice", "fun_fact": "one short fun fact"}]
        """
        let requestBody: [String: Any] = [
            "model": Self.fastModel,
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": ["responseMimeType": "application/json", "temperature": 1.0]
        ]
        guard let answerText = await DottieChat.send(requestBody, timeout: 40),
              let questions = Self.parseTrivia(answerText), !questions.isEmpty else {
            return "couldn't make the questions (gemini was busy). say sorry in a few playful words and offer to try again in a moment."
        }
        current = .trivia(category: category, questions: questions, index: 0, score: 0, hintsUsed: 0)
        return "trivia round on \(category) (\(difficulty)), \(questions.count) questions. host it like a playful game show. ask question 1 now, with its choices:\n" + Self.read(questions[0], number: 1)
            + "\npass the user's answer to game answer (a letter, a number or the words)."
    }

    // MARK: - Playing

    func answer(_ answerText: String?, myWord: String?, correct: Bool?) -> String {
        guard let current else { return "no game is running. offer one: trivia, 20 questions, guess my drawing or word chain." }
        switch current {
        case .trivia(let category, let questions, let index, let score, let hintsUsed):
            guard let answerText else { return "what did they answer?" }
            let question = questions[index]
            let isRight = Self.isTriviaAnswer(answerText, rightFor: question)
            let newScore = score + (isRight ? 1 : 0)
            var reply = isRight
                ? "right! the answer is \(question.answer). fun fact: \(question.funFact)."
                : "wrong, it was \(question.answer). fun fact: \(question.funFact)."
            let nextIndex = index + 1
            if nextIndex < questions.count {
                self.current = .trivia(category: category, questions: questions, index: nextIndex, score: newScore, hintsUsed: hintsUsed)
                reply += " score \(newScore)/\(nextIndex). react in a few words, then ask question \(nextIndex + 1):\n" + Self.read(questions[nextIndex], number: nextIndex + 1)
            } else {
                reply += " " + finishTrivia(score: newScore, total: questions.count)
            }
            return reply

        case .twentyQuestions(let dottieGuesses, let secret, let questionCount):
            let newCount = questionCount + 1
            if dottieGuesses {
                if correct == true {
                    self.current = nil
                    DottieLevels.shared.award(.gamePoints, points: 2)
                    return "you got it in \(newCount) questions! celebrate a little, then offer a rematch where they guess."
                }
                if newCount >= 20 {
                    self.current = nil
                    DottieLevels.shared.award(.gameWon)
                    return "that was question 20 and you didn't get it: the user wins! ask what it was and be a good sport."
                }
                self.current = .twentyQuestions(dottieGuesses: true, secret: nil, questionCount: newCount)
                return "\(20 - newCount) questions left. ask your next yes/no question (or guess if you're fairly sure)."
            }
            let secretText = secret ?? ""
            if let answerText, Self.matches(answerText, secret: secretText) {
                self.current = nil
                DottieLevels.shared.award(.gameWon)
                DottieLevels.shared.award(.gamePoints, points: max(1, (21 - newCount) / 4))
                return "they got it: \"\(secretText)\", in \(newCount) questions! cheer for them."
            }
            if newCount >= 20 {
                self.current = nil
                return "that was their 20th question. reveal it was \"\(secretText)\" and tease them gently. offer another round."
            }
            self.current = .twentyQuestions(dottieGuesses: false, secret: secret, questionCount: newCount)
            return "question \(newCount) of 20 (secret: \"\(secretText)\", keep it hidden). if it was a guess, it's wrong. otherwise answer honestly with yes, no or sort of."

        case .drawing:
            if correct == true {
                self.current = nil
                closeDrawingPad()
                DottieLevels.shared.award(.gameWon)
                return "you guessed their drawing! do a tiny victory moment and offer another round."
            }
            return "if your guess was wrong, try your next guess; or they can draw again and click Guess."

        case .wordChain(var usedWords, let nextLetter, var score, var lives, let waitingForDottie):
            if let myWord {
                let word = Self.normalizedWord(myWord)
                guard let wordFirst = word.first, wordFirst == nextLetter, !usedWords.contains(word), word.count > 1 else {
                    return "your word \"\(myWord)\" doesn't work (it must start with \"\(nextLetter)\" and not repeat). say a different one and call game answer with my_word again."
                }
                usedWords.append(word)
                let userLetter = word.last ?? "a"
                self.current = .wordChain(usedWords: usedWords, nextLetter: userLetter, score: score, lives: lives, waitingForDottie: false)
                return "good. the user's word must start with \"\(userLetter)\"."
            }
            guard let answerText else { return "what was their word?" }
            if waitingForDottie {
                return "it's your turn first: say a word starting with \"\(nextLetter)\" and pass it as my_word."
            }
            let word = Self.normalizedWord(answerText)
            let problem: String?
            if word.count < 2 || word.contains(" ") {
                problem = "that's not one word"
            } else if word.first != nextLetter {
                problem = "it doesn't start with \"\(nextLetter)\""
            } else if usedWords.contains(word) {
                problem = "\"\(word)\" was already used"
            } else {
                problem = nil
            }
            if let problem {
                lives -= 1
                if lives <= 0 {
                    self.current = nil
                    if score > 0 { DottieLevels.shared.award(.gamePoints, points: score) }
                    return "\(problem), and that was their last life. game over with \(score) words! be a good sport and offer a rematch."
                }
                self.current = .wordChain(usedWords: usedWords, nextLetter: nextLetter, score: score, lives: lives, waitingForDottie: false)
                return "\(problem). they lose a life (\(lives) left) and try again with a word starting with \"\(nextLetter)\"."
            }
            usedWords.append(word)
            score += 1
            if score >= 10 {
                self.current = nil
                DottieLevels.shared.award(.gameWon)
                DottieLevels.shared.award(.gamePoints, points: score)
                return "\"\(word)\" works, and that's 10 words: the user wins! celebrate."
            }
            let dottieLetter = word.last ?? "a"
            self.current = .wordChain(usedWords: usedWords, nextLetter: dottieLetter, score: score, lives: lives, waitingForDottie: true)
            return "\"\(word)\" works (\(score) words). now say one common word starting with \"\(dottieLetter)\" that isn't used yet (used: \(usedWords.suffix(15).joined(separator: ", "))), and call game answer with my_word set to it."
        }
    }

    func hint() -> String {
        guard let current else { return "no game is running." }
        switch current {
        case .trivia(let category, var questions, let index, let score, let hintsUsed):
            var question = questions[index]
            let wrongChoices = question.choices.filter { $0 != question.answer }.shuffled()
            guard wrongChoices.count >= 2, question.choices.count > 2 else {
                return "no more hints for this one. the answer starts with \"\(question.answer.prefix(1))\"."
            }
            question.choices = question.choices.filter { $0 == question.answer || $0 == wrongChoices[0] }
            questions[index] = question
            self.current = .trivia(category: category, questions: questions, index: index, score: score, hintsUsed: hintsUsed + 1)
            return "50/50: it's either \(question.choices.joined(separator: " or ")). say that playfully."
        case .twentyQuestions(let dottieGuesses, let secret, _):
            guard !dottieGuesses, let secret else { return "you're the one guessing, so no hints from you. ask a sharp question." }
            return "give a small hint about \"\(secret)\" without saying it: a category or a feature, not the answer."
        case .drawing:
            return "ask the user for a tiny hint (like how many words it is), then guess again."
        case .wordChain(let usedWords, let nextLetter, _, _, _):
            return "suggest the user think of animals, foods or places starting with \"\(nextLetter)\" (not \(usedWords.suffix(5).joined(separator: ", "))). don't give the word away."
        }
    }

    func score() -> String {
        let levelLine = " (dottie is level \(DottieLevels.shared.level), \(DottieLevels.shared.levelName).)"
        guard let current else { return "no game is running." + levelLine }
        switch current {
        case .trivia(_, let questions, let index, let score, _):
            return "trivia: \(score) right out of \(index) so far, question \(index + 1) of \(questions.count) is up." + levelLine
        case .twentyQuestions(_, _, let questionCount):
            return "20 questions: \(questionCount) asked, \(20 - questionCount) left." + levelLine
        case .drawing:
            return "guess my drawing is on." + levelLine
        case .wordChain(_, let nextLetter, let score, let lives, _):
            return "word chain: \(score) words, \(lives) lives left, next letter \"\(nextLetter)\"." + levelLine
        }
    }

    func stop() -> String {
        guard let current else { return "no game is running." }
        var reply = "game over."
        if case .trivia(_, _, let index, let score, _) = current {
            reply = finishTrivia(score: score, total: max(index, 1))
        } else if case .twentyQuestions(false, let secret?, _) = current {
            reply = "game over. reveal the secret was \"\(secret)\"."
        } else if case .wordChain(_, _, let score, _, _) = current, score > 0 {
            DottieLevels.shared.award(.gamePoints, points: score)
            reply = "game over with \(score) words."
        }
        finishSilently()
        return reply + " say bye to the game in a few fun words."
    }

    private func finishTrivia(score: Int, total: Int) -> String {
        current = nil
        if score > 0 { DottieLevels.shared.award(.gamePoints, points: score) }
        let won = score * 2 > total
        if won { DottieLevels.shared.award(.gameWon) }
        return "round over: \(score) out of \(total). \(won ? "they won! celebrate big." : "tease them kindly and offer a rematch.")"
    }

    private func finishSilently() {
        current = nil
        closeDrawingPad()
    }

    // MARK: - Guess my drawing

    private func openDrawingPad() {
        closeDrawingPad()
        let pad = DottieDrawingPadWindowController()
        pad.onGuess = { [weak self] imageData in
            guard let self else { return }
            Task { @MainActor in
                let instructions = await self.guessDrawing(imageData: imageData)
                DottieFunPack.shared.companion?.speakOnHerOwn(recordedUserText: "(guess my drawing)", instructionText: instructions)
            }
        }
        pad.onClose = { [weak self] in
            self?.drawingPad = nil
        }
        pad.show()
        drawingPad = pad
    }

    private func closeDrawingPad() {
        drawingPad?.close()
        drawingPad = nil
    }

    /// One screenshot of the screen the mouse is on, then one guess.
    private func guessDrawing(fromScreen: Bool) async -> String {
        guard let screenCaptures = try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG(),
              let capture = screenCaptures.first(where: { $0.isCursorScreen }) ?? screenCaptures.first else {
            return "couldn't look at the screen (screen recording permission?). offer the drawing pad instead."
        }
        return await guessDrawing(imageData: capture.imageData, isScreenshot: true)
    }

    private func guessDrawing(imageData: Data, isScreenshot: Bool = false) async -> String {
        let mimeType = isScreenshot ? "image/jpeg" : "image/png"
        let prompt = (isScreenshot
            ? "the user drew something on their screen for a game of guess my drawing (look for a doodle, sketch or circled drawing)."
            : "this is the user's quick mouse doodle for a game of guess my drawing.")
            + " what is it? reply with only JSON: {\"guesses\": [\"best guess\", \"second\", \"third\"], \"comment\": \"a short playful reaction to the drawing\"}"
        let requestBody: [String: Any] = [
            "model": Self.fastModel,
            "contents": [["role": "user", "parts": [
                ["inlineData": ["mimeType": mimeType, "data": imageData.base64EncodedString()]],
                ["text": prompt]
            ]]],
            "generationConfig": ["responseMimeType": "application/json"]
        ]
        guard let answerText = await DottieChat.send(requestBody, timeout: 40),
              let jsonData = Self.jsonSlice(answerText, open: "{", close: "}").data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let guesses = parsed["guesses"] as? [String], !guesses.isEmpty else {
            return "you tried to look at their drawing but gemini was busy. say so playfully and ask them to click Guess again in a moment."
        }
        let comment = (parsed["comment"] as? String) ?? ""
        return "you're playing guess my drawing and just looked at the user's drawing. your guesses, best first: \(guesses.prefix(3).joined(separator: ", then ")). your reaction: \(comment)\n"
            + "say your best guess out loud like a game show contestant and ask if you got it. if they say no, try your next guess. when you get it, call game with action answer and correct true."
    }

    // MARK: - Checking answers

    private static func read(_ question: TriviaQuestion, number: Int) -> String {
        let letters = ["A", "B", "C", "D", "E"]
        let choices = question.choices.enumerated().map { index, choice in "\(letters[min(index, 4)])) \(choice)" }
        return "Q\(number): \(question.question) " + choices.joined(separator: "  ")
    }

    static func isTriviaAnswer(_ answerText: String, rightFor question: TriviaQuestion) -> Bool {
        let given = answerText.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard let rightIndex = question.choices.firstIndex(of: question.answer) else {
            return matches(given, secret: question.answer)
        }
        let letters = ["a", "b", "c", "d", "e"]
        let spokenLetters = ["a": ["a", "ay", "option a", "letter a"], "b": ["b", "bee", "option b", "letter b"],
                             "c": ["c", "see", "sea", "option c", "letter c"], "d": ["d", "dee", "option d", "letter d"]]
        let rightLetter = letters[min(rightIndex, 4)]
        if given == rightLetter || given == "\(rightIndex + 1)" || (spokenLetters[rightLetter] ?? []).contains(given) {
            return true
        }
        if given.count == 1 || Int(given) != nil { return false }
        // Said the words: right if they match the right choice better than
        // any other choice.
        if matches(given, secret: question.answer) { return true }
        return false
    }

    /// Loose match: the guess contains the answer's main words, or the
    /// other way around.
    static func matches(_ guess: String, secret: String) -> Bool {
        func words(_ text: String) -> [String] {
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 && !["the", "and", "its", "is", "a", "an"].contains($0) }
        }
        let secretWords = words(secret)
        let guessWords = Set(words(guess).map { $0.hasSuffix("s") ? String($0.dropLast()) : $0 })
        guard !secretWords.isEmpty else { return false }
        let matched = secretWords.filter { word in
            let singular = word.hasSuffix("s") ? String(word.dropLast()) : word
            return guessWords.contains(singular)
        }
        return matched.count * 2 >= secretWords.count && !matched.isEmpty
    }

    private static func normalizedWord(_ text: String) -> String {
        text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .filter { $0.isLetter || $0 == " " || $0 == "-" }
    }

    static func parseTrivia(_ answerText: String) -> [TriviaQuestion]? {
        guard let jsonData = jsonSlice(answerText, open: "[", close: "]").data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] else { return nil }
        let questions = items.compactMap { item -> TriviaQuestion? in
            guard let question = item["question"] as? String,
                  let choices = item["choices"] as? [String], choices.count >= 2,
                  let answer = item["answer"] as? String else { return nil }
            let rightChoice = choices.first { $0.caseInsensitiveCompare(answer) == .orderedSame }
                ?? choices.first { $0.lowercased().contains(answer.lowercased()) || answer.lowercased().contains($0.lowercased()) }
            guard let rightChoice else { return nil }
            return TriviaQuestion(question: question, choices: Array(choices.prefix(4)), answer: rightChoice, funFact: (item["fun_fact"] as? String) ?? "")
        }
        return Array(questions.prefix(5))
    }

    /// The JSON in a reply, without code fences or chatter around it.
    private static func jsonSlice(_ text: String, open: Character, close: Character) -> String {
        guard let start = text.firstIndex(of: open), let end = text.lastIndex(of: close), start < end else { return text }
        return String(text[start...end])
    }

    private static let twentyQuestionsSecrets = [
        "a penguin", "a giraffe", "an octopus", "a banana", "a pizza", "a bicycle", "a lighthouse", "a rubber duck",
        "a volcano", "the moon", "a snowman", "a guitar", "a toothbrush", "an umbrella", "a dragon", "a robot",
        "a cactus", "a hot air balloon", "a submarine", "a treasure chest", "a kangaroo", "a sandwich", "a rainbow",
        "a castle", "a pirate ship", "a teapot", "a dinosaur", "a skateboard", "a honeybee", "a snow globe",
        "a telescope", "a cupcake", "a pineapple", "a hedgehog", "a lightning bolt", "a paper airplane", "a crown",
        "a jellyfish", "a train", "a sunflower"
    ]

    private static let wordChainStarters = [
        "apple", "rocket", "pizza", "tiger", "ocean", "garden", "pencil", "dragon", "candle", "mango", "jungle", "violin"
    ]
}

// MARK: - The voice tool

@MainActor
enum DottieGameTools: DottieToolModule {
    static var tools: [DottieTool] {
        [
            DottieTool(
                name: "game",
                description: "Play a game with the user: trivia (5 questions on any category), twenty_questions (you guess, or the user guesses), drawing (guess my drawing: the user doodles on a pad, or on_screen true to guess from what's on screen) or word_chain. start a game, answer passes what the user said, hint, score, stop.",
                parameters: [
                    "type": "OBJECT",
                    "properties": [
                        "action": ["type": "STRING", "enum": ["start", "answer", "hint", "score", "stop"]],
                        "game": ["type": "STRING", "enum": ["trivia", "twenty_questions", "drawing", "word_chain"], "description": "For start."],
                        "category": ["type": "STRING", "description": "Trivia: the topic, like 'space' or '90s movies'."],
                        "difficulty": ["type": "STRING", "enum": ["easy", "medium", "hard"]],
                        "who_guesses": ["type": "STRING", "enum": ["dottie", "user"], "description": "20 questions: who does the guessing."],
                        "on_screen": ["type": "BOOLEAN", "description": "Drawing: guess from what's on the screen now instead of opening the pad."],
                        "answer": ["type": "STRING", "description": "For answer: what the user said (their answer, question, guess or word)."],
                        "my_word": ["type": "STRING", "description": "Word chain: the word you just said."],
                        "correct": ["type": "BOOLEAN", "description": "true when the user says your guess was right (20 questions or drawing)."]
                    ],
                    "required": ["action"]
                ],
                audiences: [.voice]
            ) { arguments in
                let games = DottieGames.shared
                switch arguments.dottieString("action") ?? "score" {
                case "start":
                    return await games.start(
                        game: arguments.dottieString("game") ?? "trivia",
                        category: arguments.dottieString("category"),
                        difficulty: arguments.dottieString("difficulty"),
                        dottieGuesses: arguments.dottieString("who_guesses") != "user",
                        onScreen: arguments.dottieBool("on_screen") ?? false
                    )
                case "answer":
                    return games.answer(arguments.dottieString("answer"), myWord: arguments.dottieString("my_word"), correct: arguments.dottieBool("correct"))
                case "hint":
                    return games.hint()
                case "stop":
                    return games.stop()
                default:
                    return games.score()
                }
            }
        ]
    }

    static var voicePromptSection: String {
        """
        games: you love games. when the user wants to play (trivia, 20 questions, guess my drawing, word chain), call game start, then pass everything they say during it to game answer. host like a playful game show: quick, cheeky, celebrate wins, tease losses kindly, never read out rules at length. if the game tool says a secret, keep it hidden.
        """
    }
}

// MARK: - Drawing pad

/// A see-through pad over the screen the mouse is on: draw with the mouse,
/// then Guess sends the doodle to Dottie.
@MainActor
final class DottieDrawingPadWindowController {
    var onGuess: ((Data) -> Void)?
    var onClose: (() -> Void)?
    private var window: NSWindow?
    private let model = DottieDrawingPadModel()

    func show() {
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main else { return }
        let padSize = CGSize(width: min(720, screen.visibleFrame.width - 80), height: min(520, screen.visibleFrame.height - 80))
        let padFrame = CGRect(
            x: screen.visibleFrame.midX - padSize.width / 2,
            y: screen.visibleFrame.midY - padSize.height / 2,
            width: padSize.width,
            height: padSize.height
        )
        let padWindow = DottieDrawingPadWindow(contentRect: padFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        padWindow.isOpaque = false
        padWindow.backgroundColor = .clear
        padWindow.level = .floating
        padWindow.hasShadow = true
        padWindow.isReleasedWhenClosed = false
        padWindow.contentView = NSHostingView(rootView: DottieDrawingPadView(
            model: model,
            onGuess: { [weak self] in self?.guess() },
            onClose: { [weak self] in self?.close() }
        ))
        NSApp.activate(ignoringOtherApps: true)
        padWindow.makeKeyAndOrderFront(nil)
        window = padWindow
    }

    func close() {
        guard window != nil else { return }
        window?.orderOut(nil)
        window = nil
        onClose?()
    }

    private func guess() {
        guard !model.strokes.isEmpty, let imageData = model.renderPNG() else { return }
        model.isGuessing = true
        onGuess?(imageData)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            self?.model.isGuessing = false
        }
    }
}

private final class DottieDrawingPadWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class DottieDrawingPadModel: ObservableObject {
    @Published var strokes: [[CGPoint]] = []
    @Published var currentStroke: [CGPoint] = []
    @Published var isGuessing = false
    var canvasSize: CGSize = CGSize(width: 600, height: 400)

    /// The doodle in black on white, for Gemini.
    func renderPNG() -> Data? {
        let allStrokes = strokes
        let size = canvasSize
        let renderer = ImageRenderer(content:
            ZStack {
                Color.white
                DottieDrawingStrokes(strokes: allStrokes, color: .black)
            }
            .frame(width: size.width, height: size.height)
        )
        renderer.scale = 1
        guard let cgImage = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }
}

private struct DottieDrawingStrokes: View {
    let strokes: [[CGPoint]]
    let color: Color

    var body: some View {
        Path { path in
            for stroke in strokes {
                guard let first = stroke.first else { continue }
                path.move(to: first)
                if stroke.count == 1 {
                    path.addLine(to: CGPoint(x: first.x + 0.5, y: first.y + 0.5))
                }
                for point in stroke.dropFirst() {
                    path.addLine(to: point)
                }
            }
        }
        .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
    }
}

private struct DottieDrawingPadView: View {
    @ObservedObject var model: DottieDrawingPadModel
    let onGuess: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Guess my drawing")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Text("Draw with your mouse, then click Guess")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Close the pad")
            }
            GeometryReader { proxy in
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white)
                    DottieDrawingStrokes(strokes: model.strokes + [model.currentStroke], color: .black)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            model.currentStroke.append(value.location)
                        }
                        .onEnded { _ in
                            if !model.currentStroke.isEmpty {
                                model.strokes.append(model.currentStroke)
                            }
                            model.currentStroke = []
                        }
                )
                .onAppear { model.canvasSize = proxy.size }
                .onChange(of: proxy.size) { _, newSize in model.canvasSize = newSize }
            }
            HStack {
                Button("Undo") {
                    if !model.strokes.isEmpty { model.strokes.removeLast() }
                }
                .disabled(model.strokes.isEmpty)
                Button("Clear") { model.strokes = [] }
                    .disabled(model.strokes.isEmpty)
                Spacer()
                if model.isGuessing {
                    ProgressView().controlSize(.small)
                    Text("Dottie is looking…")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.7))
                }
                Button("Guess!", action: onGuess)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.strokes.isEmpty || model.isGuessing)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.88))
        )
        .preferredColorScheme(.dark)
    }
}
