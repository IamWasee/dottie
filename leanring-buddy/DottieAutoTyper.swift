//
//  DottieAutoTyper.swift
//  leanring-buddy
//
//  The human auto typer (a beta in Home → Admin, also "type this out" by
//  voice). It types a paragraph or code into the app in front one key at a
//  time with real key-down and key-up events, the way a person would: the
//  speed drifts, letters come quicker inside common pairs like "th", it
//  stops a moment at commas and longer at full stops and new lines, now and
//  then it pauses to think, and it makes typos (a neighbouring key, a
//  double press, two letters swapped, a skipped letter), sometimes keeps
//  going a few letters before noticing, then backspaces and fixes them.
//  Because every character is its own keystroke, Google Docs and the like
//  build a normal revision history.
//
//  Esc stops it at any time. Posting key events needs Accessibility.
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import Foundation

@MainActor
final class DottieAutoTyper: ObservableObject {
    static let shared = DottieAutoTyper()

    struct Settings: Codable, Equatable {
        /// The average speed it settles around.
        var wordsPerMinute: Double = 65
        /// 0…1: how uneven the rhythm and the speed drift are.
        var speedVariation: Double = 0.4
        /// 0…0.12: the chance any one letter comes out wrong.
        var typoChance: Double = 0.03
        /// Longer stops now and then, as if thinking about the next words.
        var thinkingPauses = true
        /// For a new file in a code editor: the text's own indentation after
        /// a new line is skipped (the editor indents), and before each new
        /// line whatever the editor added after the cursor (closing
        /// brackets, quotes and tags, a closing-brace line) is cleared, so
        /// nothing ends up doubled. Kept under its old name so saved
        /// settings still load.
        var editorIndentsNewLines = false
        /// Seconds between Start and the first key, to click into the field.
        var startDelaySeconds: Double = 3
    }

    enum Phase: Equatable {
        case idle
        case countingDown(secondsLeft: Int)
        case typing
        case finished
        case stopped
    }

    @Published var settings: Settings {
        didSet { saveSettings() }
    }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var typedCharacterCount = 0
    @Published private(set) var totalCharacterCount = 0
    @Published private(set) var fixedTypoCount = 0
    /// The speed it's going at right now (it drifts around the setting).
    @Published private(set) var currentWordsPerMinute: Double = 0
    /// Why the last start didn't type, for Home → Admin.
    @Published private(set) var lastProblemText: String?

    var isBusy: Bool {
        switch phase {
        case .countingDown, .typing: return true
        default: return false
        }
    }

    private static let settingsDefaultsKey = "dottieAutoTyperSettings"
    private static let notchLabel = "typing · esc stops"

    private var typingTask: Task<Void, Never>?
    /// Counts starts, so a stopped run finishing late can't end a newer one.
    private var currentRunNumber = 0
    private var isStopRequested = false
    private var globalEscapeKeyMonitor: Any?
    /// When Dottie last pressed Esc herself (to close an editor's
    /// suggestion list), so that press doesn't stop the typing.
    private var ownEscapePressedAt: Date?
    private var localEscapeKeyMonitor: Any?
    /// The last app the user had in front that isn't Dottie, so Start in
    /// Home can hand focus back to it.
    private var lastOtherFrontmostApplication: NSRunningApplication?
    private var applicationActivationObserver: NSObjectProtocol?

    /// Where each character lives on the current keyboard layout.
    private var keyStrokeByCharacter: [Character: KeyStroke] = [:]
    /// The speed multiplier that drifts slowly between words.
    private var speedDriftMultiplier: Double = 1

    private init() {
        if let savedData = UserDefaults.standard.data(forKey: Self.settingsDefaultsKey),
           let savedSettings = try? JSONDecoder().decode(Settings.self, from: savedData) {
            settings = savedSettings
        } else {
            settings = Settings()
        }
        applicationActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { notification in
            let activatedApplication = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let activatedApplication,
                      activatedApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                DottieAutoTyper.shared.lastOtherFrontmostApplication = activatedApplication
            }
        }
    }

    private func saveSettings() {
        if let encodedSettings = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(encodedSettings, forKey: Self.settingsDefaultsKey)
        }
    }

    // MARK: - Starting and stopping

    /// Starts typing `text` into whatever has keyboard focus once the
    /// countdown ends. `handFocusBackToPreviousApp` is for Start in Home:
    /// Dottie's window steps aside for the app the user was in. Returns a
    /// line for Dottie (or Home) about what happens next.
    @discardableResult
    func start(text: String, startDelaySeconds: Double? = nil, handFocusBackToPreviousApp: Bool = false) -> String {
        let textToType = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard !textToType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastProblemText = "There's nothing to type."
            return "there's no text to type."
        }
        guard AXIsProcessTrusted() else {
            lastProblemText = "Dottie needs Accessibility (System Settings → Privacy & Security → Accessibility) to press keys."
            return "typing needs the Accessibility permission. tell them to turn it on for Dottie in System Settings → Privacy & Security → Accessibility."
        }
        stop()
        lastProblemText = nil
        isStopRequested = false
        typedCharacterCount = 0
        fixedTypoCount = 0
        totalCharacterCount = textToType.count
        speedDriftMultiplier = 1
        currentWordsPerMinute = settings.wordsPerMinute
        keyStrokeByCharacter = Self.keyStrokesForCurrentKeyboardLayout()
        installEscapeKeyMonitors()

        if handFocusBackToPreviousApp {
            lastOtherFrontmostApplication?.activate()
        }

        let countdownSeconds = max(0, startDelaySeconds ?? settings.startDelaySeconds)
        currentRunNumber += 1
        let thisRunNumber = currentRunNumber
        typingTask = Task { [weak self] in
            guard let self else { return }
            await self.runCountdown(seconds: countdownSeconds)
            guard thisRunNumber == self.currentRunNumber else { return }
            guard !self.shouldStop() else {
                self.finish(as: .stopped)
                return
            }
            self.phase = .typing
            self.notchPresenter?.showThinking(label: Self.notchLabel)
            await self.typeLikeAHuman(Array(textToType))
            guard thisRunNumber == self.currentRunNumber else { return }
            self.finish(as: self.isStopRequested ? .stopped : .finished)
        }

        let wordCount = textToType.split(whereSeparator: { $0.isWhitespace }).count
        let roughMinutes = Double(wordCount) / max(settings.wordsPerMinute, 1)
        let roughDuration = roughMinutes < 1 ? "under a minute" : "about \(Int(roughMinutes.rounded())) minute\(Int(roughMinutes.rounded()) == 1 ? "" : "s")"
        return "typing \(wordCount) words into the app in front in \(Int(countdownSeconds.rounded())) seconds, at about \(Int(settings.wordsPerMinute)) words a minute with typos and fixes; it'll take \(roughDuration). esc stops it. say so in a few words."
    }

    func stop() {
        isStopRequested = true
        typingTask?.cancel()
        typingTask = nil
        if isBusy { finish(as: .stopped) }
    }

    private func finish(as finalPhase: Phase) {
        guard isBusy else { return }
        phase = finalPhase
        removeEscapeKeyMonitors()
        // Only the typer's own notch label is taken down, never Dottie's.
        if let notchPresenter, notchPresenter.surface == .thinking, notchPresenter.activityLabel.hasPrefix("typing") {
            notchPresenter.collapse()
        }
    }

    var statusForVoice: String {
        switch phase {
        case .idle: return "the auto typer isn't typing anything."
        case .countingDown(let secondsLeft): return "starting to type in \(secondsLeft) seconds."
        case .typing: return "typing: \(typedCharacterCount) of \(totalCharacterCount) characters done, \(fixedTypoCount) typos fixed, about \(Int(currentWordsPerMinute)) words a minute."
        case .finished: return "finished typing \(totalCharacterCount) characters (\(fixedTypoCount) typos fixed)."
        case .stopped: return "stopped after \(typedCharacterCount) of \(totalCharacterCount) characters."
        }
    }

    private var notchPresenter: NotchPresenter? { DottieFunPack.shared.companion?.notchPresenter }

    private func runCountdown(seconds: Double) async {
        var secondsLeft = Int(seconds.rounded(.up))
        while secondsLeft > 0 && !shouldStop() {
            phase = .countingDown(secondsLeft: secondsLeft)
            notchPresenter?.showThinking(label: "typing in \(secondsLeft)…")
            await pause(seconds: 1)
            secondsLeft -= 1
        }
    }

    // MARK: - Esc stops

    private func installEscapeKeyMonitors() {
        removeEscapeKeyMonitors()
        globalEscapeKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { keyEvent in
            guard keyEvent.keyCode == UInt16(kVK_Escape) else { return }
            Task { @MainActor in
                if let ownEscapePressedAt = DottieAutoTyper.shared.ownEscapePressedAt,
                   Date().timeIntervalSince(ownEscapePressedAt) < 0.5 { return }
                DottieAutoTyper.shared.stop()
            }
        }
        localEscapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { keyEvent in
            guard keyEvent.keyCode == UInt16(kVK_Escape) else { return keyEvent }
            Task { @MainActor in DottieAutoTyper.shared.stop() }
            return nil
        }
    }

    private func removeEscapeKeyMonitors() {
        if let globalEscapeKeyMonitor { NSEvent.removeMonitor(globalEscapeKeyMonitor) }
        if let localEscapeKeyMonitor { NSEvent.removeMonitor(localEscapeKeyMonitor) }
        globalEscapeKeyMonitor = nil
        localEscapeKeyMonitor = nil
    }

    /// Also asks the keyboard directly whether Esc is down, in case the
    /// event monitors can't see it.
    private func shouldStop() -> Bool {
        if isStopRequested || Task.isCancelled { return true }
        if CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Escape)) {
            isStopRequested = true
            return true
        }
        return false
    }

    /// Sleeps in short slices so Esc is noticed even during a long pause.
    private func pause(seconds: Double) async {
        var secondsLeft = seconds
        while secondsLeft > 0 && !shouldStop() {
            let slice = min(secondsLeft, 0.05)
            try? await Task.sleep(nanoseconds: UInt64(slice * 1_000_000_000))
            secondsLeft -= slice
        }
    }

    // MARK: - Typing

    /// One typo: what gets typed instead of `correctLength` characters of the
    /// text starting at the typo.
    private struct Typo {
        let wrongCharacters: [Character]
        let correctLength: Int
    }

    private func typeLikeAHuman(_ characters: [Character]) async {
        var characterIndex = 0
        // Right after fixing a typo, those letters are typed carefully.
        var noTyposBeforeIndex = 0
        var previousCharacter: Character?

        while characterIndex < characters.count {
            if shouldStop() { return }
            let character = characters[characterIndex]

            if characterIndex >= noTyposBeforeIndex,
               let typo = makeTypo(in: characters, at: characterIndex) {
                // The slip itself, at normal speed.
                for wrongCharacter in typo.wrongCharacters {
                    await typeCharacter(wrongCharacter, after: previousCharacter)
                    previousCharacter = wrongCharacter
                    if shouldStop() { return }
                }
                // Often a few more letters go by before the mistake is noticed.
                let lettersBeforeNoticing = lettersTypedBeforeNoticing(in: characters, from: characterIndex + typo.correctLength)
                for extraIndex in 0..<lettersBeforeNoticing {
                    let extraCharacter = characters[characterIndex + typo.correctLength + extraIndex]
                    await typeCharacter(extraCharacter, after: previousCharacter)
                    previousCharacter = extraCharacter
                    if shouldStop() { return }
                }
                // Notice, backspace quickly, a breath, then type it right.
                await pause(seconds: Double.random(in: 0.25...0.75))
                for _ in 0..<(typo.wrongCharacters.count + lettersBeforeNoticing) {
                    pressKey(keyCode: CGKeyCode(kVK_Delete))
                    await pause(seconds: Double.random(in: 0.06...0.14))
                    if shouldStop() { return }
                }
                await pause(seconds: Double.random(in: 0.1...0.3))
                fixedTypoCount += 1
                previousCharacter = characterIndex > 0 ? characters[characterIndex - 1] : nil
                noTyposBeforeIndex = characterIndex + typo.correctLength + lettersBeforeNoticing
                continue
            }

            await typeCharacter(character, after: previousCharacter)
            previousCharacter = character
            characterIndex += 1
            typedCharacterCount = characterIndex

            // An editor that indents new lines itself would double the text's
            // own indentation, so it's skipped.
            if character == "\n" && settings.editorIndentsNewLines {
                while characterIndex < characters.count, characters[characterIndex] == " " || characters[characterIndex] == "\t" {
                    characterIndex += 1
                }
                typedCharacterCount = characterIndex
            }

            await pause(seconds: pauseAfterTyping(character, nextCharacter: characterIndex < characters.count ? characters[characterIndex] : nil))
        }
        // The last line has no new line after it to clear the editor's
        // additions, so they're cleared once more at the end.
        if settings.editorIndentsNewLines && !shouldStop() {
            await clearWhatTheEditorAddedAfterTheCursor(lineEndsWithWord: false)
        }
    }

    /// Presses the key (or keys) for one character, then waits the gap
    /// before the next key.
    private func typeCharacter(_ character: Character, after previousCharacter: Character?) async {
        switch character {
        case "\n":
            if settings.editorIndentsNewLines {
                await clearWhatTheEditorAddedAfterTheCursor(lineEndsWithWord: previousCharacter.map { $0.isLetter || $0.isNumber || $0 == "_" } ?? false)
            }
            pressKey(keyCode: CGKeyCode(kVK_Return))
        case "\t":
            pressKey(keyCode: CGKeyCode(kVK_Tab))
        default:
            if let keyStroke = keyStrokeByCharacter[character] {
                await pressKeyStroke(keyStroke, typing: character)
            } else {
                // Not on this keyboard (an emoji, a curly quote): sent as the
                // character itself, still as its own key down and up.
                pressUnicodeCharacter(character)
            }
        }
        await pause(seconds: gapBeforeNextKey(after: character, previousCharacter: previousCharacter))
    }

    // MARK: - Code editors

    /// Code editors type ahead of you: "(" adds ")", a quote adds its pair,
    /// "<div>" adds "</div>", and Return inside "{}" pushes the "}" onto a
    /// line below. The text already has all of those, so they came out
    /// twice. Closers typed on the same line just step over the editor's
    /// own (editors do that), and before every new line everything after
    /// the cursor, which in a new file is only what the editor added, is
    /// selected and removed. A suggestion list still open at the end of a
    /// word would take the Return, so Esc closes it first (not in Xcode,
    /// where Esc opens one).
    private func clearWhatTheEditorAddedAfterTheCursor(lineEndsWithWord: Bool) async {
        let frontAppIsXcode = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.dt.Xcode"
        if lineEndsWithWord && !frontAppIsXcode {
            ownEscapePressedAt = Date()
            pressKey(keyCode: CGKeyCode(kVK_Escape))
            await pause(seconds: Double.random(in: 0.05...0.1))
        }
        // Shift+Cmd+Down selects to the end of the file; Forward Delete
        // removes the selection, and does nothing when there is none.
        pressKey(keyCode: CGKeyCode(kVK_DownArrow), flags: [.maskShift, .maskCommand])
        await pause(seconds: 0.03)
        pressKey(keyCode: CGKeyCode(kVK_ForwardDelete))
        await pause(seconds: 0.03)
    }

    // MARK: - Rhythm

    /// The time between two keys: the current speed, wobbled per key,
    /// quicker inside common letter pairs, slower for capitals, digits and
    /// symbols.
    private func gapBeforeNextKey(after character: Character, previousCharacter: Character?) -> Double {
        // A word is five characters, so this is the average gap.
        let averageGapSeconds = 60.0 / (max(currentWordsPerMinute, 5) * 5)
        // Key-to-key time is skewed: mostly near the average, sometimes much longer.
        let wobble = exp(Self.randomNormal() * (0.15 + 0.35 * settings.speedVariation))
        var gapSeconds = averageGapSeconds * wobble

        if let previousCharacter {
            let letterPair = String(previousCharacter).lowercased() + String(character).lowercased()
            if Self.quickLetterPairs.contains(letterPair) { gapSeconds *= 0.7 }
            if previousCharacter.lowercased() == character.lowercased() && character.isLetter { gapSeconds *= 0.85 }
        }
        if character.isUppercase { gapSeconds += Double.random(in: 0.04...0.12) }
        if character.isNumber { gapSeconds *= 1.35 }
        if !character.isLetter && !character.isNumber && !character.isWhitespace { gapSeconds *= 1.5 }
        return min(max(gapSeconds, 0.025), 1.2)
    }

    /// The extra stop after a character: a beat after words, more after
    /// commas, more again after sentences and lines, and now and then a
    /// longer think.
    private func pauseAfterTyping(_ character: Character, nextCharacter: Character?) -> Double {
        var pauseSeconds = 0.0
        let isWordEnd = character == " " || character == "\n"

        switch character {
        case " ":
            pauseSeconds += Double.random(in: 0...0.08)
        case ",", ";", ":":
            if nextCharacter == " " || nextCharacter == "\n" { pauseSeconds += Double.random(in: 0.15...0.4) }
        case ".", "!", "?":
            if nextCharacter == " " || nextCharacter == "\n" || nextCharacter == nil {
                pauseSeconds += Double.random(in: 0.3...0.9)
                if settings.thinkingPauses && Double.random(in: 0...1) < 0.15 {
                    pauseSeconds += Double.random(in: 1...2.5)
                }
            }
        case "\n":
            pauseSeconds += Double.random(in: 0.35...1.1)
        default:
            break
        }

        if isWordEnd {
            // The speed drifts a little every word, like a real typist
            // warming up and slowing down.
            let driftStep = Self.randomNormal() * 0.06 * (0.3 + settings.speedVariation)
            let driftLimit = 0.1 + 0.3 * settings.speedVariation
            speedDriftMultiplier = min(max(speedDriftMultiplier + driftStep, 1 - driftLimit), 1 + driftLimit)
            currentWordsPerMinute = settings.wordsPerMinute * speedDriftMultiplier

            if settings.thinkingPauses && Double.random(in: 0...1) < 0.025 {
                pauseSeconds += Double.random(in: 1.2...3.5)
            }
        }
        return pauseSeconds
    }

    /// Letter pairs most people type in one quick roll.
    private static let quickLetterPairs: Set<String> = [
        "th", "he", "in", "er", "an", "re", "on", "at", "en", "nd", "ti", "es", "or", "te",
        "of", "ed", "is", "it", "al", "ar", "st", "to", "nt", "ng", "se", "ha", "as", "ou",
        "io", "le", "ve", "co", "me", "de", "hi", "ri", "ro", "ic", "ne", "ea", "ra", "ce"
    ]

    /// A standard normal random number (Box–Muller).
    private static func randomNormal() -> Double {
        let firstUniform = Double.random(in: Double.ulpOfOne...1)
        let secondUniform = Double.random(in: 0...1)
        return sqrt(-2 * log(firstUniform)) * cos(2 * .pi * secondUniform)
    }

    // MARK: - Typos

    private func makeTypo(in characters: [Character], at characterIndex: Int) -> Typo? {
        let character = characters[characterIndex]
        guard character.isLetter, character.isASCII, settings.typoChance > 0,
              Double.random(in: 0...1) < settings.typoChance else { return nil }
        let nextCharacter: Character? = characterIndex + 1 < characters.count ? characters[characterIndex + 1] : nil
        let nextIsLetter = nextCharacter.map { $0.isLetter && $0.isASCII } ?? false

        let typoKindRoll = Double.random(in: 0...1)
        if typoKindRoll < 0.15, let nextCharacter, nextIsLetter, nextCharacter != character {
            // Two letters swapped: "teh".
            return Typo(wrongCharacters: [nextCharacter, character], correctLength: 2)
        }
        if typoKindRoll < 0.28, let nextCharacter, nextIsLetter {
            // A letter skipped: "tis" for "this".
            return Typo(wrongCharacters: [nextCharacter], correctLength: 2)
        }
        if typoKindRoll < 0.4 {
            // A key pressed twice: "thhe".
            return Typo(wrongCharacters: [character, character], correctLength: 1)
        }
        // The key next to the right one.
        guard let neighbouringKeys = Self.neighbouringKeysOnQwerty[Character(character.lowercased())],
              let neighbouringKey = neighbouringKeys.randomElement() else { return nil }
        let wrongCharacter = character.isUppercase ? Character(neighbouringKey.uppercased()) : neighbouringKey
        return Typo(wrongCharacters: [wrongCharacter], correctLength: 1)
    }

    /// How many more correct letters go by before the typo is noticed:
    /// usually none, sometimes up to three, never past the end of a line or
    /// past anything but letters and spaces (so code editors' auto-closing
    /// brackets never get involved).
    private func lettersTypedBeforeNoticing(in characters: [Character], from startIndex: Int) -> Int {
        guard Double.random(in: 0...1) < 0.4 else { return 0 }
        let wantedCount = Int.random(in: 1...3)
        var count = 0
        while count < wantedCount, startIndex + count < characters.count {
            let upcomingCharacter = characters[startIndex + count]
            guard upcomingCharacter == " " || (upcomingCharacter.isLetter && upcomingCharacter.isASCII) else { break }
            count += 1
        }
        return count
    }

    private static let neighbouringKeysOnQwerty: [Character: [Character]] = [
        "q": ["w", "a"], "w": ["q", "e", "s"], "e": ["w", "r", "d"], "r": ["e", "t", "f"],
        "t": ["r", "y", "g"], "y": ["t", "u", "h"], "u": ["y", "i", "j"], "i": ["u", "o", "k"],
        "o": ["i", "p", "l"], "p": ["o", "l"], "a": ["q", "s", "z"], "s": ["a", "d", "w", "x"],
        "d": ["s", "f", "e", "c"], "f": ["d", "g", "r", "v"], "g": ["f", "h", "t", "b"],
        "h": ["g", "j", "y", "n"], "j": ["h", "k", "u", "m"], "k": ["j", "l", "i"],
        "l": ["k", "o"], "z": ["a", "x"], "x": ["z", "c", "s"], "c": ["x", "v", "d"],
        "v": ["c", "b", "f"], "b": ["v", "n", "g"], "n": ["b", "m", "h"], "m": ["n", "j"]
    ]

    // MARK: - Key events

    /// A physical key and the modifiers that make it type a character.
    private struct KeyStroke {
        let keyCode: CGKeyCode
        let needsShift: Bool
        let needsOption: Bool
    }

    /// Real key down and key up for one character, holding Shift (and
    /// Option) around it like a person does. The character is attached too,
    /// so apps that read the text rather than the key code agree.
    private func pressKeyStroke(_ keyStroke: KeyStroke, typing character: Character) async {
        let eventSource = CGEventSource(stateID: .hidSystemState)
        var modifierFlags: CGEventFlags = []
        if keyStroke.needsShift { modifierFlags.insert(.maskShift) }
        if keyStroke.needsOption { modifierFlags.insert(.maskAlternate) }

        if keyStroke.needsShift {
            postModifierChange(keyCode: CGKeyCode(kVK_Shift), flags: [.maskShift], eventSource: eventSource)
        }
        if keyStroke.needsOption {
            postModifierChange(keyCode: CGKeyCode(kVK_Option), flags: modifierFlags, eventSource: eventSource)
        }
        if !modifierFlags.isEmpty { await pause(seconds: Double.random(in: 0.02...0.05)) }

        var characterUTF16 = Array(String(character).utf16)
        let keyDownEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: keyStroke.keyCode, keyDown: true)
        keyDownEvent?.flags = modifierFlags
        keyDownEvent?.keyboardSetUnicodeString(stringLength: characterUTF16.count, unicodeString: &characterUTF16)
        keyDownEvent?.post(tap: .cghidEventTap)

        // How long the key stays down.
        await pause(seconds: Double.random(in: 0.03...0.09))

        let keyUpEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: keyStroke.keyCode, keyDown: false)
        keyUpEvent?.flags = modifierFlags
        keyUpEvent?.keyboardSetUnicodeString(stringLength: characterUTF16.count, unicodeString: &characterUTF16)
        keyUpEvent?.post(tap: .cghidEventTap)

        if keyStroke.needsOption {
            postModifierChange(keyCode: CGKeyCode(kVK_Option), flags: keyStroke.needsShift ? [.maskShift] : [], eventSource: eventSource)
        }
        if keyStroke.needsShift {
            postModifierChange(keyCode: CGKeyCode(kVK_Shift), flags: [], eventSource: eventSource)
        }
    }

    private func postModifierChange(keyCode: CGKeyCode, flags: CGEventFlags, eventSource: CGEventSource?) {
        let modifierEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: !flags.isEmpty)
        modifierEvent?.type = .flagsChanged
        modifierEvent?.flags = flags
        modifierEvent?.post(tap: .cghidEventTap)
    }

    /// Return, Tab and Delete, with no modifiers (so a held talk shortcut
    /// can't turn Return into something else).
    private func pressKey(keyCode: CGKeyCode, flags: CGEventFlags = []) {
        let eventSource = CGEventSource(stateID: .hidSystemState)
        for isKeyDown in [true, false] {
            let keyEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: isKeyDown)
            keyEvent?.flags = flags
            keyEvent?.post(tap: .cghidEventTap)
        }
    }

    private func pressUnicodeCharacter(_ character: Character) {
        let eventSource = CGEventSource(stateID: .hidSystemState)
        var characterUTF16 = Array(String(character).utf16)
        for isKeyDown in [true, false] {
            let keyEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: isKeyDown)
            keyEvent?.flags = []
            keyEvent?.keyboardSetUnicodeString(stringLength: characterUTF16.count, unicodeString: &characterUTF16)
            keyEvent?.post(tap: .cghidEventTap)
        }
    }

    /// Asks the current keyboard layout which key (with Shift or Option)
    /// types each character, so the events carry the real key codes.
    /// Plain keys win over Shift, Shift over Option, and the main keys over
    /// the number pad.
    private static func keyStrokesForCurrentKeyboardLayout() -> [Character: KeyStroke] {
        guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutDataPointer = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
            return [:]
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataPointer).takeUnretainedValue() as Data
        // Carbon modifier bits, shifted the way UCKeyTranslate wants them.
        let modifierCombinations: [(modifierKeyState: UInt32, needsShift: Bool, needsOption: Bool)] = [
            (0, false, false),
            (UInt32(shiftKey >> 8) & 0xFF, true, false),
            (UInt32(optionKey >> 8) & 0xFF, false, true),
            (UInt32((shiftKey | optionKey) >> 8) & 0xFF, true, true)
        ]
        // Keys that type control characters, handled on their own.
        let skippedKeyCodes: Set<Int> = [kVK_Return, kVK_Tab, kVK_Delete, kVK_Escape, kVK_ANSI_KeypadEnter, kVK_ForwardDelete]

        var keyStrokeByCharacter: [Character: KeyStroke] = [:]
        layoutData.withUnsafeBytes { rawLayoutBytes in
            guard let keyboardLayout = rawLayoutBytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for modifierCombination in modifierCombinations {
                for keyCode in 0..<128 where !skippedKeyCodes.contains(keyCode) {
                    var deadKeyState: UInt32 = 0
                    var typedCharacters = [UniChar](repeating: 0, count: 4)
                    var typedLength = 0
                    let maximumTypedLength = typedCharacters.count
                    let translateStatus = UCKeyTranslate(
                        keyboardLayout,
                        UInt16(keyCode),
                        UInt16(kUCKeyActionDown),
                        modifierCombination.modifierKeyState,
                        UInt32(LMGetKbdType()),
                        OptionBits(1 << kUCKeyTranslateNoDeadKeysBit),
                        &deadKeyState,
                        maximumTypedLength,
                        &typedLength,
                        &typedCharacters
                    )
                    guard translateStatus == noErr, typedLength == 1, typedCharacters[0] >= 0x20, typedCharacters[0] != 0x7F,
                          let unicodeScalar = Unicode.Scalar(typedCharacters[0]) else { continue }
                    let character = Character(unicodeScalar)
                    if keyStrokeByCharacter[character] == nil {
                        keyStrokeByCharacter[character] = KeyStroke(
                            keyCode: CGKeyCode(keyCode),
                            needsShift: modifierCombination.needsShift,
                            needsOption: modifierCombination.needsOption
                        )
                    }
                }
            }
        }
        return keyStrokeByCharacter
    }
}

// MARK: - The voice tool

@MainActor
enum DottieAutoTyperTools: DottieToolModule {
    static var tools: [DottieTool] {
        [
            DottieTool(
                name: "auto_type",
                description: "Human auto typer (beta): types text into the app in front like a person, key by key with real key presses, uneven speed, pauses and typos it backspaces and fixes, so docs get a normal edit history. Use when they ask to type something out like a human, auto type, or type what's on their clipboard. action start types `text` (write it yourself if they asked you to write something, keeping code exactly as is) or their clipboard with from_clipboard; stop stops it; status says how far it is. Esc also stops it.",
                parameters: [
                    "type": "OBJECT",
                    "properties": [
                        "action": ["type": "STRING", "enum": ["start", "stop", "status"]],
                        "text": ["type": "STRING", "description": "For start: exactly what to type."],
                        "from_clipboard": ["type": "BOOLEAN", "description": "For start: type what's on their clipboard instead."],
                        "words_per_minute": ["type": "NUMBER", "description": "Optional speed if they named one (20 to 160)."],
                        "typos": ["type": "BOOLEAN", "description": "Optional: false if they want no typos."],
                        "code_editor": ["type": "BOOLEAN", "description": "Optional: true when typing code into a new file in a code editor (VS Code, IntelliJ, Xcode…), so the editor's own indenting and closing brackets, quotes and tags aren't doubled; false for normal text."]
                    ],
                    "required": ["action"]
                ],
                audiences: [.voice]
            ) { arguments in
                let autoTyper = DottieAutoTyper.shared
                guard DottieAdminMode.shared.isUnlocked else {
                    return "auto typing is a locked beta feature. say it's locked, without hinting at how to unlock it."
                }
                switch arguments.dottieString("action") ?? "status" {
                case "stop":
                    autoTyper.stop()
                    return "stopped typing."
                case "start":
                    let textToType: String
                    if arguments.dottieBool("from_clipboard") == true {
                        textToType = NSPasteboard.general.string(forType: .string) ?? ""
                    } else {
                        textToType = (arguments["text"] as? String) ?? ""
                    }
                    if let wordsPerMinute = arguments.dottieNumber("words_per_minute") {
                        autoTyper.settings.wordsPerMinute = min(max(wordsPerMinute, 20), 160)
                    }
                    if let typosWanted = arguments.dottieBool("typos") {
                        if !typosWanted {
                            autoTyper.settings.typoChance = 0
                        } else if autoTyper.settings.typoChance == 0 {
                            autoTyper.settings.typoChance = DottieAutoTyper.Settings().typoChance
                        }
                    }
                    if let typingIntoCodeEditor = arguments.dottieBool("code_editor") {
                        autoTyper.settings.editorIndentsNewLines = typingIntoCodeEditor
                    }
                    // The talk shortcut is still being let go of; a short
                    // wait keeps it out of the first keys.
                    return autoTyper.start(text: textToType, startDelaySeconds: 2)
                default:
                    return autoTyper.statusForVoice
                }
            }
        ]
    }

    static var voicePromptSection: String {
        DottieAdminMode.isUnlockedInDefaults
            ? "to type text out like a human (beta), find and use auto_type."
            : ""
    }
}
