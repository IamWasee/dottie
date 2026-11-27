//
//  DottieJevDriver.swift
//  leanring-buddy
//
//  Jev drives screen jobs. Jev (TypeSafe's System One model) writes no text,
//  but it reads the goal and the screen and picks one option from a list,
//  so every step Dottie hands it every move she could make right now: click
//  any text on screen, type a piece of the user's own words (with or
//  without Return), scroll, go back, open a site or an app the request
//  names, search the web, "it's done" or "none of these". Jev's pick is the
//  next move; any planning happens inside the model. On a screen it doesn't
//  know it explores: a move that changes nothing is struck off for that
//  screen and the next best one is tried. When Jev is unsure, says none
//  fits, keeps repeating itself or the job wants an answer read out, the
//  existing step model (GLM) takes over from where Jev got to.
//

import AppKit
import Foundation
import Vision

/// The pure half: options, Jev's request, reading its answer and deciding.
/// Foundation only, so it's unit tested.
enum DottieJevDriverPlan {
    /// A line of text read on the screen, with its middle in 0-1000 of the
    /// screenshot, top-left origin (the way the models' boxes read).
    struct ScreenText: Equatable {
        let text: String
        let centerX: Double
        let centerY: Double
    }

    /// A control the front app names through Accessibility (a button, a
    /// link, a text box, an icon with a description), with its middle in
    /// 0-1000 of the screenshot, top-left origin. Icons have no text for
    /// OCR to read, so these are how Jev gets to click them.
    struct ScreenControl: Equatable {
        let label: String
        let kind: String
        let centerX: Double
        let centerY: Double
    }

    enum Move: Equatable {
        case click(label: String, centerX: Double, centerY: Double)
        case clickControl(label: String, kind: String, centerX: Double, centerY: Double)
        /// Jev circles the icon or control itself (it has no words or name).
        case clickUnlabeled
        case doubleClick(label: String, centerX: Double, centerY: Double)
        case rightClick(label: String, centerX: Double, centerY: Double)
        /// Point the mouse at it without clicking: menus and controls that
        /// only show while the mouse is over something. The pointer stays.
        case hover(label: String, centerX: Double, centerY: Double)
        case drag(fromLabel: String, fromX: Double, fromY: Double, toLabel: String, toX: Double, toY: Double)
        case typeText(String, pressesReturn: Bool)
        /// Click a text box, then type into it: one move, so the typing
        /// never lands nowhere because the box wasn't selected.
        case typeIntoField(fieldLabel: String, centerX: Double, centerY: Double, text: String, pressesReturn: Bool)
        case pressReturn
        case pressKeys(keys: String, meaning: String)
        case scrollDown
        case scrollUp
        case scrollLeft
        case scrollRight
        case goBack
        case openSite(address: String)
        case searchWeb(String)
        case openApp(name: String)
        /// The instant lane and Needle on the Mac (open an app, move a
        /// window, volume, music), with no screen at all.
        case quickMacAction(String)
        /// Read what app memory knows about the app in front (pages,
        /// controls, the user's flows), only when Jev asks for it.
        case recallAppMemory
        /// Press the mouse button down on something and keep holding it
        /// (a long press, the start of a drag, a slider); a later move lets go.
        case holdMouseDown(label: String, centerX: Double, centerY: Double)
        /// Let go of the held button where it was pressed.
        case releaseMouseHere
        /// Move there with the button still held, then let go (a drop).
        case releaseMouseOn(label: String, centerX: Double, centerY: Double)
        /// One round of a job that repeats the same task is done: the next starts.
        case finishedRound
        case finished
        case noneFits

        /// What Jev reads for this option.
        var description: String {
            switch self {
            case .click(let label, _, _): return "Click \"\(label)\" on the screen"
            case .clickControl(let label, let kind, _, _): return "Click the \(kind) \"\(label)\""
            case .clickUnlabeled: return "Click an icon, picture or button that has no words on it (Dottie finds the one that helps)"
            case .doubleClick(let label, _, _): return "Double-click \"\(label)\" (opens a file, folder or item)"
            case .rightClick(let label, _, _): return "Right-click \"\(label)\" for its menu"
            case .hover(let label, _, _): return "Point the mouse at \"\(label)\" without clicking (opens a menu or controls that only show while the mouse is over it)"
            case .drag(let fromLabel, _, _, let toLabel, _, _): return "Drag \"\(fromLabel)\" onto \"\(toLabel)\""
            case .pressKeys(let keys, let meaning): return "Press \(keys) (\(meaning))"
            case .scrollLeft: return "Scroll or swipe left"
            case .scrollRight: return "Scroll or swipe right"
            case .quickMacAction(let text): return "Do it straight on the Mac without the screen: \"\(text)\""
            case .recallAppMemory: return "Look up what Dottie remembers about this app first (its buttons, where they are, and how the user did this before)"
            case .typeIntoField(let fieldLabel, _, _, let text, let pressesReturn):
                return pressesReturn
                    ? "Click the text box \"\(fieldLabel)\", type \"\(text)\", then press Return"
                    : "Click the text box \"\(fieldLabel)\" and type \"\(text)\""
            case .typeText(let text, let pressesReturn):
                return pressesReturn
                    ? "Type \"\(text)\" into the text box that's selected now, then press Return"
                    : "Type \"\(text)\" into the text box that's selected now"
            case .pressReturn: return "Press Return"
            case .scrollDown: return "Scroll down to see more"
            case .scrollUp: return "Scroll up"
            case .goBack: return "Go back to the page before (the last move didn't help)"
            case .openSite(let address): return "Open the website \(address)"
            case .searchWeb(let text): return "Search the web for \"\(text)\""
            case .openApp(let name): return "Open the app \(name)"
            case .holdMouseDown(let label, _, _): return "Press and hold the mouse button down on \"\(label)\" (don't let go yet)"
            case .releaseMouseHere: return "Let go of the mouse button where it's held"
            case .releaseMouseOn(let label, _, _): return "Move what's held onto \"\(label)\" and let go of the mouse button there"
            case .finishedRound: return "This round of the task is done: start the next round"
            case .finished: return "Nothing left to do: the goal is already done on this screen"
            case .noneFits: return "None of these moves helps with the goal"
            }
        }

        /// Moves that load a page or an app, which take longer to draw.
        var opensSomethingNew: Bool {
            switch self {
            case .openSite, .searchWeb, .openApp, .goBack, .pressReturn, .doubleClick, .pressKeys, .quickMacAction: return true
            case .typeText(_, let pressesReturn): return pressesReturn
            case .typeIntoField(_, _, _, _, let pressesReturn): return pressesReturn
            case .click, .clickControl, .clickUnlabeled, .rightClick, .hover, .drag, .scrollDown, .scrollUp, .scrollLeft, .scrollRight, .recallAppMemory,
                 .holdMouseDown, .releaseMouseHere, .releaseMouseOn, .finishedRound, .finished, .noneFits: return false
            }
        }

        /// Where on the screen (0-1) the move acts, for moves aimed at one
        /// spot: checked again right before acting, in case the page moved.
        var aimedPoint: (centerX: Double, centerY: Double)? {
            switch self {
            case .click(_, let centerX, let centerY), .clickControl(_, _, let centerX, let centerY),
                 .doubleClick(_, let centerX, let centerY), .rightClick(_, let centerX, let centerY),
                 .hover(_, let centerX, let centerY), .typeIntoField(_, let centerX, let centerY, _, _), .holdMouseDown(_, let centerX, let centerY),
                 .releaseMouseOn(_, let centerX, let centerY):
                return (centerX, centerY)
            case .drag(_, let fromX, let fromY, _, _, _):
                return (fromX, fromY)
            case .clickUnlabeled, .typeText, .pressReturn, .pressKeys, .scrollDown, .scrollUp, .scrollLeft, .scrollRight, .goBack,
                 .openSite, .searchWeb, .openApp, .quickMacAction, .recallAppMemory, .releaseMouseHere, .finishedRound, .finished, .noneFits:
                return nil
            }
        }

        /// The same move on the same screen is the same move, wherever OCR
        /// put the label's middle this time.
        var signature: String {
            switch self {
            case .click(let label, _, _): return "click:\(label.lowercased())"
            // The same thing found by OCR or by Accessibility is one move.
            case .clickControl(let label, _, _, _): return "click:\(label.lowercased())"
            case .doubleClick(let label, _, _): return "doubleclick:\(label.lowercased())"
            case .rightClick(let label, _, _): return "rightclick:\(label.lowercased())"
            case .hover(let label, _, _): return "hover:\(label.lowercased())"
            case .drag(let fromLabel, _, _, let toLabel, _, _): return "drag:\(fromLabel.lowercased())>\(toLabel.lowercased())"
            case .holdMouseDown(let label, _, _): return "hold:\(label.lowercased())"
            case .releaseMouseOn(let label, _, _): return "release:\(label.lowercased())"
            default: return description.lowercased()
            }
        }

        /// A line for the step model's hand-over note and the progress card.
        var summary: String {
            switch self {
            case .click(let label, _, _): return "clicked \(label)"
            case .clickControl(let label, let kind, _, _): return "clicked the \(kind) \(label)"
            case .clickUnlabeled: return "clicked an icon"
            case .doubleClick(let label, _, _): return "double-clicked \(label)"
            case .rightClick(let label, _, _): return "right-clicked \(label)"
            case .hover(let label, _, _): return "pointed the mouse at \(label)"
            case .drag(let fromLabel, _, _, let toLabel, _, _): return "dragged \(fromLabel) onto \(toLabel)"
            case .pressKeys(let keys, _): return "pressed \(keys)"
            case .scrollLeft: return "scrolled left"
            case .scrollRight: return "scrolled right"
            case .quickMacAction(let text): return "did \"\(text)\" on the Mac"
            case .recallAppMemory: return "looked up what Dottie remembers about this app"
            case .typeText(let text, let pressesReturn): return pressesReturn ? "typed \"\(text)\" and pressed Return" : "typed \"\(text)\""
            case .typeIntoField(let fieldLabel, _, _, let text, let pressesReturn):
                return pressesReturn ? "typed \"\(text)\" into \(fieldLabel) and pressed Return" : "typed \"\(text)\" into \(fieldLabel)"
            case .pressReturn: return "pressed Return"
            case .scrollDown: return "scrolled down"
            case .scrollUp: return "scrolled up"
            case .goBack: return "went back"
            case .openSite(let address): return "opened \(address)"
            case .searchWeb(let text): return "searched the web for \(text)"
            case .openApp(let name): return "opened \(name)"
            case .holdMouseDown(let label, _, _): return "pressed and held the mouse on \(label)"
            case .releaseMouseHere: return "let go of the mouse"
            case .releaseMouseOn(let label, _, _): return "moved what was held onto \(label) and let go"
            case .finishedRound: return "finished this round"
            case .finished: return "finished"
            case .noneFits: return "stopped"
            }
        }
    }

    struct Option: Equatable {
        let key: String
        let move: Move
        /// What app memory remembers about this move here ("Dottie clicked
        /// this here before and it opened …"), shown beside it.
        var memoryNote: String? = nil

        /// The option as Jev and the advisor read it.
        var textForModels: String {
            memoryNote.map { move.description + " (\($0))" } ?? move.description
        }
    }

    struct Answer: Equatable {
        let move: Move
        let probability: Double
        let confidence: Double
        let doneProbability: Double?
        /// Jev's check of the move before this one, on this screen: how
        /// likely it worked and moved the request forward. Nil on the
        /// first step or when Jev didn't answer the check.
        var lastMoveWorkedProbability: Double? = nil
    }

    enum Decision: Equatable {
        case act(Move)
        /// One round of a repeated job is done; the job goes on.
        case roundDone
        case finished
        case unsure
    }

    static let choiceQuestionName = "next_move"
    static let doneQuestionName = "done"
    static let stepCheckQuestionName = "last_move_worked"
    /// Jev's step check below this means the last move didn't work.
    static let lastMoveWorkedThreshold = 0.3
    /// This many failed step checks in a row hand the job over.
    static let maximumFailedStepChecks = 2
    /// Jev takes up to 255 options; this many screen texts leaves room.
    static let maximumScreenTextOptions = 120
    /// Every option together stays under Jev's 255; screen texts give way first.
    static let maximumOptions = 250
    static let maximumControlOptions = 50
    static let maximumDoubleAndRightClickTargets = 8
    /// Text boxes that get "click it and type" options, and pieces per box.
    static let maximumTypingFields = 4
    static let maximumPiecesPerField = 3
    /// Jev saying the goal is done this surely ends the job.
    static let doneProbabilityToFinish = 0.8
    /// Below both of these Jev is guessing among many; the step model goes on.
    static let minimumConfidence = 0.15
    static let minimumTopProbability = 0.2
    /// The Jev lane's own step budget before the step model takes over.
    static let maximumSteps = 25
    /// A job that repeats gets the budget once per round, up to this. Long
    /// jobs stay light: their memory is saved and trimmed every 100 moves
    /// (DottieJobLedger).
    static let maximumStepsForRepeatedJobs = maximumSteps * DottieJobMemory.maximumRounds

    static func stepBudget(rounds: Int) -> Int {
        min(maximumSteps * max(rounds, 1), maximumStepsForRepeatedJobs)
    }
    /// This many moves in a row that change nothing hand over.
    static let maximumMovesWithoutChange = 3

    // MARK: Pieces of the request

    /// Words the job may need typed, taken from the user's own request:
    /// quoted text, and what follows "search for", "type", "called" and the
    /// like, up to "on", "in", "and", a quote mark, a bracket or the end.
    /// Claude's task line `search "MrBeast" (go to youtube.com…)` used to
    /// give the piece `MrBeast" (go`, which became the search (27 Nov).
    static func textPieces(from taskText: String) -> [String] {
        var pieces: [String] = []
        let quotePattern = "[\"“”]([^\"“”]{1,120})[\"“”]"
        for match in matches(of: quotePattern, in: taskText) {
            pieces.append(match)
        }
        let leadPattern = "(?i)\\b(?:search(?:ing|ed|es)?(?: for| up)?|look(?:ing)? up|typ(?:e|ing)|writ(?:e|ing)|enter(?:ing)?|called|named|titled|say(?:ing)?)\\s+(?!(?:button|bar|box|field|icon|results?|tab|page|engine|history|filters?|settings)\\b)([^\"“”()\\[\\]]+?)(?=\\s+(?:on|in|into|and then|and|then|to|at|from|using|click|tap|press|play|open|watch|turn|select|pick|choose)\\s|\\s*[\"“”()\\[\\]]|[,.!?]|$)"
        for match in matches(of: leadPattern, in: taskText) {
            let piece = match.trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”"))
            if !piece.isEmpty { pieces.append(piece) }
        }
        var seenPieces = Set<String>()
        return pieces.filter { piece in
            let comparablePiece = piece.lowercased()
            guard !seenPieces.contains(comparablePiece), comparablePiece.count <= 120 else { return false }
            seenPieces.insert(comparablePiece)
            return true
        }
    }

    /// Sites everyone calls by name.
    static let siteAddressesByName: [String: String] = [
        "youtube": "youtube.com", "gmail": "mail.google.com", "google drive": "drive.google.com", "google docs": "docs.google.com",
        "google sheets": "sheets.google.com", "google calendar": "calendar.google.com", "google maps": "maps.google.com",
        "google": "google.com", "netflix": "netflix.com", "amazon": "amazon.com", "facebook": "facebook.com",
        "instagram": "instagram.com", "twitter": "x.com", "reddit": "reddit.com", "linkedin": "linkedin.com",
        "github": "github.com", "kaggle": "kaggle.com", "wikipedia": "wikipedia.org", "spotify web": "open.spotify.com",
        "chatgpt": "chatgpt.com", "tiktok": "tiktok.com", "twitch": "twitch.tv", "pinterest": "pinterest.com",
        "notion": "notion.so", "canva": "canva.com", "figma": "figma.com", "outlook": "outlook.live.com",
        "whatsapp": "web.whatsapp.com", "discord": "discord.com", "ebay": "ebay.com", "roblox": "roblox.com"
    ]

    /// Sites whose search results open straight from an address, so
    /// "search mr beast on youtube" is one move instead of finding the
    /// search box, clicking it and typing.
    static let searchAddressTemplates: [String: String] = [
        "youtube.com": "youtube.com/results?search_query=",
        "google.com": "google.com/search?q=",
        "amazon.com": "amazon.com/s?k=",
        "wikipedia.org": "en.wikipedia.org/w/index.php?search=",
        "reddit.com": "reddit.com/search/?q=",
        "github.com": "github.com/search?q=",
        "ebay.com": "ebay.com/sch/i.html?_nkw=",
        "x.com": "x.com/search?q=",
        "tiktok.com": "tiktok.com/search?q=",
        "twitch.tv": "twitch.tv/search?term=",
        "pinterest.com": "pinterest.com/search/pins/?q=",
        "kaggle.com": "kaggle.com/search?q=",
        "netflix.com": "netflix.com/search?q="
    ]

    /// The search results page on each named site that has one, for each
    /// thing the request says to search for.
    static func searchResultAddresses(siteAddresses: [String], textPieces: [String]) -> [String] {
        var addresses: [String] = []
        for siteAddress in siteAddresses {
            guard let template = searchAddressTemplates[siteAddress.lowercased()] else { continue }
            for textPiece in textPieces.prefix(2) {
                let encodedPiece = textPiece.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? textPiece
                addresses.append(template + encodedPiece)
            }
        }
        return addresses
    }

    /// Whether the browser in front is already on this site
    /// ("www.youtube.com" is on "youtube.com").
    static func isSiteAlreadyOpen(_ siteAddress: String, frontSiteHost: String?) -> Bool {
        guard let frontSiteHost = frontSiteHost?.lowercased(), !frontSiteHost.isEmpty else { return false }
        let siteHost = siteAddress.lowercased()
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .split(separator: "/").first.map(String.init) ?? ""
        guard !siteHost.isEmpty else { return false }
        let bareSiteHost = siteHost.hasPrefix("www.") ? String(siteHost.dropFirst(4)) : siteHost
        return frontSiteHost == bareSiteHost || frontSiteHost.hasSuffix("." + bareSiteHost)
    }

    /// Web addresses the request names: typed ones ("kaggle.com/competitions")
    /// and sites said by name ("open youtube"), longest names first so
    /// "google docs" isn't read as "google".
    static func siteAddresses(from taskText: String) -> [String] {
        var addresses: [String] = []
        let typedAddressPattern = "(?i)\\b((?:https?://)?(?:[a-z0-9-]+\\.)+(?:com|org|net|io|ai|dev|co|tv|so|edu|gov|me|gg|uk|bd)\\b(?:/[^\\s,]*)?)"
        addresses.append(contentsOf: matches(of: typedAddressPattern, in: taskText))
        var remainingText = " " + comparableWords(taskText) + " "
        for siteName in siteAddressesByName.keys.sorted(by: { $0.count > $1.count }) where remainingText.contains(" \(siteName) ") {
            if let address = siteAddressesByName[siteName] { addresses.append(address) }
            remainingText = remainingText.replacingOccurrences(of: " \(siteName) ", with: " ")
        }
        var seenAddresses = Set<String>()
        return addresses.filter { seenAddresses.insert($0.lowercased()).inserted }
    }

    /// One, two and three word groups of the request, to look up as app names.
    static func wordGroups(of taskText: String) -> [String] {
        let words = comparableWords(taskText).split(separator: " ").map(String.init)
        var groups: [String] = []
        for groupLength in [3, 2, 1] where words.count >= groupLength {
            for startIndex in 0...(words.count - groupLength) {
                groups.append(words[startIndex..<(startIndex + groupLength)].joined(separator: " "))
            }
        }
        return groups.filter { $0.count >= 3 && !commonWords.contains($0) }
    }

    /// Words that are never an app's name on their own.
    private static let commonWords: Set<String> = [
        "the", "and", "for", "open", "click", "go", "to", "my", "on", "in", "it", "this", "that", "then", "search",
        "find", "type", "please", "can", "you", "me", "new", "get", "put", "set", "make", "see", "show", "tell"
    ]

    /// Jobs whose result is something read off the screen ("tell me my
    /// rank"): Jev can find it, but only the step model can say it.
    static func asksForInformation(_ taskText: String) -> Bool {
        let lowercasedTask = taskText.lowercased()
        let askingPhrases = ["tell me", "what is", "what's", "whats", "how many", "how much", "read me", "let me know", "check if", "check whether", "find out", "which ", "who ", "when ", "?"]
        return askingPhrases.contains { lowercasedTask.contains($0) }
    }

    /// Buttons that spend, send or destroy are only pressed when the user's
    /// own words asked for that.
    static func isRiskyLabel(_ label: String, forTask taskText: String) -> Bool {
        let riskyNeedlesForThisTask = riskyNeedlesNotAskedFor(byComparableTask: " " + comparableWords(taskText) + " ")
        return isRiskyComparableLabel(" " + comparableWords(label) + " ", riskyNeedles: riskyNeedlesForThisTask)
    }

    private static let riskyWords = ["buy", "pay", "purchase", "checkout", "order", "delete", "remove", "send", "post", "publish", "transfer", "unsubscribe", "erase", "sign out", "log out"]

    /// Each risky word as it's looked for inside a comparable label
    /// (" buy"), made once instead of for every text on every screen.
    private static let riskyNeedles = riskyWords.map { " " + $0 }

    /// The risky words the request itself doesn't name, worked out once per
    /// step, so a screen with hundreds of texts doesn't redo it for each one.
    private static func riskyNeedlesNotAskedFor(byComparableTask comparableTask: String) -> [String] {
        riskyNeedles.filter { !comparableTask.contains($0) }
    }

    private static func isRiskyComparableLabel(_ paddedComparableLabel: String, riskyNeedles: [String]) -> Bool {
        riskyNeedles.contains { paddedComparableLabel.contains($0) }
    }

    // MARK: Options

    /// Screen texts worth offering as clicks: short lines with letters,
    /// each once, top to bottom.
    static func clickableTexts(from screenTexts: [ScreenText], taskText: String) -> [ScreenText] {
        var seenTexts = Set<String>()
        let riskyNeedlesForThisTask = riskyNeedlesNotAskedFor(byComparableTask: " " + comparableWords(taskText) + " ")
        let usefulTexts = screenTexts.filter { screenText in
            let trimmedText = screenText.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // The cheap checks first, so long or letterless texts never get
            // made comparable at all.
            guard (2...60).contains(trimmedText.count),
                  trimmedText.rangeOfCharacter(from: .letters) != nil else { return false }
            let comparableText = comparableWords(trimmedText)
            guard !isRiskyComparableLabel(" " + comparableText + " ", riskyNeedles: riskyNeedlesForThisTask),
                  seenTexts.insert(comparableText).inserted else { return false }
            return true
        }
        return Array(usefulTexts.sorted { ($0.centerY, $0.centerX) < ($1.centerY, $1.centerX) }.prefix(maximumScreenTextOptions))
    }

    /// Every move Dottie could make now, less the ones already tried on
    /// this same screen, keyed o1, o2, … for Jev.
    static func options(
        screenTexts: [ScreenText],
        textPieces: [String],
        siteAddresses: [String],
        appNames: [String],
        alreadyTriedSignatures: Set<String>,
        frontSiteHost: String? = nil,
        screenControls: [ScreenControl] = [],
        taskText: String = "",
        offersAppMemory: Bool = false,
        offersNextRound: Bool = false,
        extraLeadingMoves: [Move] = [],
        isBrowserInFront: Bool = false,
        frontAppBundleIdentifier: String? = nil
    ) -> [Option] {
        // Moves the user's own hint names (keys to press) come first.
        var leadingMoves: [Move] = extraLeadingMoves
        if offersAppMemory { leadingMoves.append(.recallAppMemory) }
        for textPiece in textPieces {
            leadingMoves.append(.typeText(textPiece, pressesReturn: true))
            leadingMoves.append(.typeText(textPiece, pressesReturn: false))
        }
        leadingMoves.append(contentsOf: searchResultAddresses(siteAddresses: siteAddresses, textPieces: textPieces).map { Move.openSite(address: $0) })
        // A site the browser in front already shows isn't offered again:
        // "click the search button" on YouTube reopened YouTube instead.
        let sitesToOffer = siteAddresses.filter { !isSiteAlreadyOpen($0, frontSiteHost: frontSiteHost) }
        leadingMoves.append(contentsOf: sitesToOffer.map { Move.openSite(address: $0) })
        leadingMoves.append(contentsOf: appNames.map { Move.openApp(name: $0) })
        leadingMoves.append(contentsOf: textPieces.prefix(2).map { Move.searchWeb($0) })
        let trimmedTaskText = taskText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTaskText.isEmpty, trimmedTaskText.count <= 120 {
            leadingMoves.append(.quickMacAction(trimmedTaskText))
        }
        leadingMoves.append(contentsOf: typeIntoFieldMoves(screenControls: screenControls, textPieces: textPieces))
        leadingMoves.append(contentsOf: controlsWorthOffering(screenControls, screenTexts: screenTexts, taskText: taskText).map {
            Move.clickControl(label: $0.label, kind: $0.kind, centerX: $0.centerX, centerY: $0.centerY)
        })

        var trailingMoves: [Move] = [.clickUnlabeled]
        for target in doubleAndRightClickTargets(screenTexts: screenTexts, taskText: taskText) {
            trailingMoves.append(.doubleClick(label: target.text, centerX: target.centerX, centerY: target.centerY))
            trailingMoves.append(.rightClick(label: target.text, centerX: target.centerX, centerY: target.centerY))
        }
        if let dragMove = dragMove(taskText: taskText, screenTexts: screenTexts) {
            trailingMoves.append(dragMove)
        }
        trailingMoves.append(contentsOf: holdMoves(screenTexts: screenTexts, screenControls: screenControls, taskText: taskText))
        trailingMoves.append(contentsOf: hoverMoves(screenTexts: screenTexts, screenControls: screenControls, taskText: taskText))
        trailingMoves.append(contentsOf: [.pressReturn, .scrollDown, .scrollUp, .scrollLeft, .scrollRight, .goBack])
        // Quick commands for where the user is (Mac, browser, YouTube,
        // Finder), risky ones loudly labeled and only when asked for.
        let quickCommands = DottieJevQuickCommands.commands(
            forTask: taskText, isBrowserInFront: isBrowserInFront || frontSiteHost != nil,
            frontSiteHost: frontSiteHost, frontAppBundleIdentifier: frontAppBundleIdentifier
        )
        trailingMoves.append(contentsOf: quickCommands.map { Move.pressKeys(keys: $0.keys, meaning: $0.labeledMeaning) })
        // A repeated job isn't finished while rounds are left: the round is.
        trailingMoves.append(contentsOf: offersNextRound ? [.finishedRound, .noneFits] : [.finished, .noneFits])

        // Screen texts fill what's left of Jev's option limit.
        let screenTextBudget = max(0, maximumOptions - leadingMoves.count - trailingMoves.count)
        let textClickMoves = screenTexts.prefix(screenTextBudget).map { Move.click(label: $0.text, centerX: $0.centerX, centerY: $0.centerY) }
        let moves = leadingMoves + textClickMoves + trailingMoves
        var seenSignatures = Set<String>()
        let freshMoves = moves.filter { move in
            let moveSignature = move.signature
            guard !alreadyTriedSignatures.contains(moveSignature) else { return false }
            return seenSignatures.insert(moveSignature).inserted
        }
        return freshMoves.enumerated().map { index, move in Option(key: "o\(index + 1)", move: move) }
    }

    /// Requests that need the button held: long presses, drags, sliders.
    static func asksToHoldOrDrag(_ taskText: String) -> Bool {
        let paddedTask = " " + comparableWords(taskText) + " "
        return [" hold ", " long press ", " press and hold ", " drag ", " slide ", " slider ", " draw ", " select from "].contains { paddedTask.contains($0) }
    }

    static let maximumHoldTargets = 20

    /// "Press and hold" on the texts the request talks about and on
    /// sliders, and on the screen's texts when the request asks to hold or
    /// drag, so a drag can be done in steps (hold, look, let go).
    static func holdMoves(screenTexts: [ScreenText], screenControls: [ScreenControl], taskText: String) -> [Move] {
        var moves: [Move] = screenControls.filter { $0.kind == "slider" }.prefix(4).map {
            Move.holdMouseDown(label: $0.label, centerX: $0.centerX, centerY: $0.centerY)
        }
        let targets = asksToHoldOrDrag(taskText)
            ? Array(screenTexts.prefix(maximumHoldTargets))
            : doubleAndRightClickTargets(screenTexts: screenTexts, taskText: taskText)
        moves.append(contentsOf: targets.map { Move.holdMouseDown(label: $0.text, centerX: $0.centerX, centerY: $0.centerY) })
        return moves
    }

    /// Requests that talk about hovering or the menus that open from it.
    static func asksToHover(_ taskText: String) -> Bool {
        let paddedTask = " " + comparableWords(taskText) + " "
        return [" hover", " mouse over ", " mouseover ", " roll over ", " dropdown ", " drop down ", " submenu ", " sub menu ", " menu "].contains { paddedTask.contains($0) }
    }

    static let maximumHoverTargets = 20
    /// Texts this near the top (0-1000) are often a site's top menu, whose
    /// menus open on hover.
    static let topMenuBand = 160.0
    static let maximumTopMenuHoverTargets = 8

    /// "Point the mouse at" moves: the screen's menu buttons, the texts the
    /// request talks about and the short texts along the top (a site's
    /// menu), or the screen's texts when the request talks about hovering
    /// or menus. Few, so screen texts keep their room under Jev's limit.
    static func hoverMoves(screenTexts: [ScreenText], screenControls: [ScreenControl], taskText: String) -> [Move] {
        var targets: [(label: String, centerX: Double, centerY: Double)] = screenControls.filter { $0.kind == "menu" }.prefix(6).map {
            (label: $0.label, centerX: $0.centerX, centerY: $0.centerY)
        }
        let textTargets: [ScreenText]
        if asksToHover(taskText) {
            textTargets = Array(screenTexts.prefix(maximumHoverTargets))
        } else {
            let topMenuTexts = screenTexts.filter { screenText in
                screenText.centerY <= topMenuBand && screenText.text.split(separator: " ").count <= 3
            }.prefix(maximumTopMenuHoverTargets)
            textTargets = doubleAndRightClickTargets(screenTexts: screenTexts, taskText: taskText) + topMenuTexts
        }
        targets.append(contentsOf: textTargets.map { (label: $0.text, centerX: $0.centerX, centerY: $0.centerY) })
        return targets.prefix(maximumHoverTargets).map { Move.hover(label: $0.label, centerX: $0.centerX, centerY: $0.centerY) }
    }

    /// The moves while the mouse button is held down: let go where it is,
    /// or carry what's held onto a text or control and let go there.
    /// Nothing else is offered until the button is let go.
    static func optionsWhileHoldingMouse(heldLabel: String, screenTexts: [ScreenText], screenControls: [ScreenControl], alreadyTriedSignatures: Set<String>) -> [Option] {
        var moves: [Move] = [.releaseMouseHere]
        let comparableHeldLabel = comparableWords(heldLabel)
        let dropTargets = screenControls.map { (label: $0.label, centerX: $0.centerX, centerY: $0.centerY) }
            + screenTexts.map { (label: $0.text, centerX: $0.centerX, centerY: $0.centerY) }
        for dropTarget in dropTargets where comparableWords(dropTarget.label) != comparableHeldLabel {
            moves.append(.releaseMouseOn(label: dropTarget.label, centerX: dropTarget.centerX, centerY: dropTarget.centerY))
        }
        var seenSignatures = Set<String>()
        let freshMoves = moves.filter { move in
            let moveSignature = move.signature
            guard move == .releaseMouseHere || !alreadyTriedSignatures.contains(moveSignature) else { return false }
            return seenSignatures.insert(moveSignature).inserted
        }
        // "None fits" always stays, inside Jev's option limit.
        let offeredMoves = Array(freshMoves.prefix(maximumOptions - 1)) + [.noneFits]
        return offeredMoves.enumerated().map { index, move in Option(key: "o\(index + 1)", move: move) }
    }

    /// "Click this text box and type this" for the screen's text boxes
    /// (top to bottom) and the first pieces of text, with and without Return.
    static func typeIntoFieldMoves(screenControls: [ScreenControl], textPieces: [String]) -> [Move] {
        let textBoxes = screenControls.filter { $0.kind == "text box" }
            .sorted { ($0.centerY, $0.centerX) < ($1.centerY, $1.centerX) }
            .prefix(maximumTypingFields)
        var moves: [Move] = []
        for textBox in textBoxes {
            for textPiece in textPieces.prefix(maximumPiecesPerField) {
                moves.append(.typeIntoField(fieldLabel: textBox.label, centerX: textBox.centerX, centerY: textBox.centerY, text: textPiece, pressesReturn: true))
                moves.append(.typeIntoField(fieldLabel: textBox.label, centerX: textBox.centerX, centerY: textBox.centerY, text: textPiece, pressesReturn: false))
            }
        }
        return moves
    }

    /// What Accessibility calls a kind of control, in words Jev reads, or
    /// nil for kinds that aren't clicked (groups, plain text, windows).
    static func controlKind(forRole role: String) -> String? {
        switch role {
        case "AXButton": return "button"
        case "AXLink": return "link"
        case "AXTextField", "AXSearchField", "AXTextArea", "AXComboBox": return "text box"
        case "AXCheckBox": return "checkbox"
        case "AXRadioButton", "AXTab": return "tab"
        case "AXPopUpButton", "AXMenuButton": return "menu"
        case "AXMenuItem", "AXMenuBarItem": return "menu item"
        case "AXImage": return "picture"
        case "AXCell", "AXRow": return "item"
        case "AXDisclosureTriangle": return "arrow"
        case "AXIncrementor", "AXSlider": return "slider"
        default: return nil
        }
    }

    /// A control's Accessibility frame (top-left origin on the primary
    /// display, in points) as a ScreenControl on this screenshot, or nil
    /// when its middle is off this display or it has no size.
    static func screenControl(label: String, role: String, accessibilityFrame: CGRect, displayFrame: CGRect, primaryDisplayHeight: CGFloat) -> ScreenControl? {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let kind = controlKind(forRole: role), !trimmedLabel.isEmpty, trimmedLabel.count <= 60,
              accessibilityFrame.width > 0, accessibilityFrame.height > 0,
              displayFrame.width > 0, displayFrame.height > 0 else { return nil }
        let middleX = accessibilityFrame.midX
        let middleYFromBottom = primaryDisplayHeight - accessibilityFrame.midY
        guard middleX >= displayFrame.minX, middleX <= displayFrame.maxX,
              middleYFromBottom >= displayFrame.minY, middleYFromBottom <= displayFrame.maxY else { return nil }
        return ScreenControl(
            label: trimmedLabel,
            kind: kind,
            centerX: Double((middleX - displayFrame.minX) / displayFrame.width) * 1000,
            centerY: Double((displayFrame.maxY - middleYFromBottom) / displayFrame.height) * 1000
        )
    }

    /// Controls Jev doesn't already get as a screen text, no risky ones
    /// the request didn't ask for, each once, top to bottom, capped.
    static func controlsWorthOffering(_ screenControls: [ScreenControl], screenTexts: [ScreenText], taskText: String) -> [ScreenControl] {
        var seenLabels = Set(screenTexts.map { comparableWords($0.text) })
        let riskyNeedlesForThisTask = riskyNeedlesNotAskedFor(byComparableTask: " " + comparableWords(taskText) + " ")
        let freshControls = screenControls.filter { control in
            let comparableLabel = comparableWords(control.label)
            guard !comparableLabel.isEmpty,
                  !isRiskyComparableLabel(" " + comparableLabel + " ", riskyNeedles: riskyNeedlesForThisTask) else { return false }
            return seenLabels.insert(comparableLabel).inserted
        }
        return Array(freshControls.sorted { ($0.centerY, $0.centerX) < ($1.centerY, $1.centerX) }.prefix(maximumControlOptions))
    }

    /// Words that say what a request is about (three letters or more, not
    /// an action word), to pick which screen texts get double and right clicks.
    static func contentWords(of taskText: String) -> Set<String> {
        let actionWords: Set<String> = ["open", "click", "double", "right", "drag", "move", "the", "and", "then", "into", "onto", "from", "with", "this", "that", "please", "file", "folder"]
        return Set(comparableWords(taskText).split(separator: " ").map(String.init).filter { $0.count >= 3 && !actionWords.contains($0) })
    }

    /// Screen texts that share a word with the request, which get a
    /// double-click and a right-click option too (offering them for every
    /// text would push Jev past its option limit).
    static func doubleAndRightClickTargets(screenTexts: [ScreenText], taskText: String) -> [ScreenText] {
        let taskWords = contentWords(of: taskText)
        guard !taskWords.isEmpty else { return [] }
        let matchingTexts = screenTexts.filter { screenText in
            !taskWords.isDisjoint(with: comparableWords(screenText.text).split(separator: " ").map(String.init))
        }
        return Array(matchingTexts.prefix(maximumDoubleAndRightClickTargets))
    }

    /// "drag the report onto the desktop" / "move invoice.pdf to Archive":
    /// one drag between the screen texts that best match each side, or nil.
    static func dragMove(taskText: String, screenTexts: [ScreenText]) -> Move? {
        let dragPattern = "(?i)\\b(?:drag|move)\\s+(?:the\\s+)?(.+?)\\s+(?:onto|into|to|over)\\s+(?:the\\s+)?(.+?)(?=[,.!?]|\\s+and\\s|$)"
        guard let expression = try? NSRegularExpression(pattern: dragPattern),
              let match = expression.firstMatch(in: taskText, range: NSRange(taskText.startIndex..., in: taskText)),
              match.numberOfRanges > 2,
              let fromRange = Range(match.range(at: 1), in: taskText),
              let toRange = Range(match.range(at: 2), in: taskText) else { return nil }
        guard let fromText = bestMatchingText(for: String(taskText[fromRange]), in: screenTexts),
              let toText = bestMatchingText(for: String(taskText[toRange]), in: screenTexts),
              fromText != toText else { return nil }
        return .drag(fromLabel: fromText.text, fromX: fromText.centerX, fromY: fromText.centerY,
                     toLabel: toText.text, toX: toText.centerX, toY: toText.centerY)
    }

    /// The screen text sharing the most words with `phrase`, or nil.
    private static func bestMatchingText(for phrase: String, in screenTexts: [ScreenText]) -> ScreenText? {
        let phraseWords = Set(comparableWords(phrase).split(separator: " ").map(String.init))
        guard !phraseWords.isEmpty else { return nil }
        var bestText: ScreenText?
        var bestSharedCount = 0
        for screenText in screenTexts {
            let sharedCount = phraseWords.intersection(comparableWords(screenText.text).split(separator: " ").map(String.init)).count
            if sharedCount > bestSharedCount {
                bestSharedCount = sharedCount
                bestText = screenText
            }
        }
        return bestText
    }

    /// Jev's request: the goal and what's been done as state, the moves as
    /// one choice question and "is it done?" as a yes/no beside it. The
    /// screenshot asset is added by DottieJev.answer(to:screenImage:).
    // MARK: Step checks

    /// Moves that open something (a site, a search, an app). Once one has
    /// worked it isn't offered again in the same round: on Wasee's Mac a
    /// job opened YouTube, then a YouTube search in a new tab, clicked the
    /// first video, then opened the same search in yet another tab,
    /// because the open move came back as soon as the screen changed.
    static func opensOnlyOnce(_ move: Move) -> Bool {
        switch move {
        case .openSite, .searchWeb, .openApp: return true
        default: return false
        }
    }

    /// Whether Jev's step check says the last move didn't work.
    /// A move that changed the screen counts as failed only when Jev is
    /// sure: on Wasee's Mac (27 Nov) the check said "didn't work" nine
    /// times in a row, after moves that opened YouTube and its results, and
    /// every second "no" handed the job over.
    static let lastMoveWorkedThresholdWhenScreenChanged = 0.1

    static func lastMoveFailed(_ answer: Answer, screenChangedAfterMove: Bool = false) -> Bool {
        guard let lastMoveWorkedProbability = answer.lastMoveWorkedProbability else { return false }
        let threshold = screenChangedAfterMove ? lastMoveWorkedThresholdWhenScreenChanged : lastMoveWorkedThreshold
        return lastMoveWorkedProbability < threshold
    }

    /// The question Jev answers about the last move, looking at the screen
    /// it left, in the same call that picks the next move (no extra call).
    static func stepCheckInstructions(lastMoveSummary: String) -> String {
        "Dottie's last move was: \(lastMoveSummary). Looking at this screen, did that move work and bring the user's request closer: what it was meant to open, show or change is showing now, and nothing was opened twice or went somewhere else?"
    }

    /// A site opened while the browser in front already shows the same
    /// site, or a page this job opened, replaces that tab instead of
    /// opening another one. A tab the user had open on another site is
    /// left alone.
    static func opensInSameTab(address: String, frontSiteHost: String?, hostsOpenedByThisJob: Set<String>) -> Bool {
        guard let frontSiteHost = frontSiteHost?.lowercased(), !frontSiteHost.isEmpty else { return false }
        if isSiteAlreadyOpen(address, frontSiteHost: frontSiteHost) { return true }
        let bareFrontHost = frontSiteHost.hasPrefix("www.") ? String(frontSiteHost.dropFirst(4)) : frontSiteHost
        return hostsOpenedByThisJob.contains { openedHost in
            let bareOpenedHost = openedHost.hasPrefix("www.") ? String(openedHost.dropFirst(4)) : openedHost
            return bareOpenedHost == bareFrontHost
        }
    }

    /// The Google search page for a piece of the request.
    static func searchAddress(for text: String) -> String {
        var searchComponents = URLComponents(string: "https://www.google.com/search")
        searchComponents?.queryItems = [URLQueryItem(name: "q", value: text)]
        return searchComponents?.url?.absoluteString ?? "google.com"
    }

    /// The host a move opens in the browser, if it opens a page.
    static func openedHost(of move: Move) -> String? {
        switch move {
        case .openSite(let address): return host(ofAddress: address)
        case .searchWeb(let text): return host(ofAddress: searchAddress(for: text))
        default: return nil
        }
    }

    /// The host an open move goes to ("youtube.com/results?…" → "youtube.com").
    static func host(ofAddress address: String) -> String? {
        let withScheme = address.contains("://") ? address : "https://" + address
        return URL(string: withScheme)?.host?.lowercased()
    }

    /// The "done?" question Jev answers every step. A finished job rarely
    /// shows the whole request on one screen (the last of two new patients
    /// is on screen, not both), so the last round of a repeated job asks
    /// about that round alone, and a single job counts its result showing
    /// (saved, sent, added, a success message) as done (Wasee, 28 Nov: jobs
    /// that really finished never said so).
    static func doneQuestionInstructions(jobMemory: DottieJobMemory?) -> String {
        if let jobMemory, jobMemory.isRepeatedJob {
            if jobMemory.hasRoundsLeft {
                return "Is round \(jobMemory.currentRound) of the task finished on this screen?"
            }
            return "This is the last round (round \(jobMemory.currentRound) of \(jobMemory.totalRounds)); the earlier rounds are already done. Is this last round finished on this screen?"
        }
        return "Is the user's request fully done on this screen already? Say yes when the moves so far did every part of it and this screen shows the result: the thing saved, sent, added, created or opened, a success message, or the new item on its own page or in a list."
    }

    static func requestBody(
        goal: String,
        movesSoFar: [String],
        knownHowTo: String,
        options: [Option],
        jobMemory: DottieJobMemory? = nil,
        hintsText: String = "",
        isHoldingMouse: Bool = false,
        lastMoveSummary: String? = nil
    ) -> [String: Any] {
        var state = "The user asked Dottie, their Mac assistant, to do this on their Mac: \(goal)\n\(DottieJevProtocol.screenshotReferenceLine) (their screen right now)."
        if let jobMemory {
            state += "\n" + jobMemory.stateText()
        } else if movesSoFar.isEmpty {
            state += "\nNothing has been done yet."
        } else {
            state += "\nDone so far, in order: " + DottieJobMemory.compactList(movesSoFar) + "."
        }
        if isHoldingMouse {
            state += "\nThe mouse button is held down right now: let go of it (where it is, or on the place the held thing should go)."
        }
        let trimmedHints = hintsText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedHints.isEmpty {
            state += "\n" + trimmedHints
        }
        let trimmedHowTo = knownHowTo.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedHowTo.isEmpty {
            state += "\nWhat Dottie knows about this kind of job: " + String(trimmedHowTo.prefix(4500))
        }
        var criteria: [String: String] = [:]
        for option in options {
            criteria[option.key] = option.textForModels
        }
        var questions: [String: Any] = [
            choiceQuestionName: [
                "type": "choice",
                "instructions": "Pick the one next move that gets the user's request done, the way a person sitting at this Mac would do it next. If the app or site isn't open yet, open it first. Never redo a step that already worked: carry on from what this screen shows. Click a text box before typing into it. A keyboard shortcut or a named button is often quickest; pick the icon option only when the thing to click has no words or name.",
                "criteria": criteria
            ],
            doneQuestionName: [
                "type": "noul",
                "instructions": doneQuestionInstructions(jobMemory: jobMemory)
            ]
        ]
        if let lastMoveSummary, !lastMoveSummary.isEmpty {
            questions[stepCheckQuestionName] = [
                "type": "noul",
                "instructions": stepCheckInstructions(lastMoveSummary: lastMoveSummary)
            ]
        }
        return [
            "state": state,
            "questions": questions
        ]
    }

    /// The move Jev chose, how sure it is and its "done" chance, or nil.
    static func answer(fromAnswer answerData: Data, options: [Option]) -> Answer? {
        guard let answerObject = try? JSONSerialization.jsonObject(with: answerData) as? [String: Any],
              let answers = answerObject["answers"] as? [String: Any],
              let choiceAnswer = answers[choiceQuestionName] as? [String: Any],
              let chosenKey = choiceAnswer["choice"] as? String,
              let chosenOption = options.first(where: { $0.key == chosenKey }) else { return nil }
        let probabilities = choiceAnswer["probabilities"] as? [String: Any]
        let probability = number(probabilities?[chosenKey]) ?? 0
        let confidence = number(choiceAnswer["confidence"]) ?? 0
        let doneAnswer = answers[doneQuestionName] as? [String: Any]
        let doneProbability = number(doneAnswer?["noul"]) ?? number(doneAnswer?["probability"]) ?? number(doneAnswer?["value"])
        let stepCheckAnswer = answers[stepCheckQuestionName] as? [String: Any]
        let lastMoveWorkedProbability = number(stepCheckAnswer?["noul"]) ?? number(stepCheckAnswer?["probability"]) ?? number(stepCheckAnswer?["value"])
        return Answer(move: chosenOption.move, probability: probability, confidence: confidence, doneProbability: doneProbability,
                      lastMoveWorkedProbability: lastMoveWorkedProbability)
    }

    /// `hasRoundsLeft`: a repeated job with rounds still to do, where
    /// "done" ends the round, not the job (only once the round made a move:
    /// a new round starts on a screen that looks finished).
    /// `heldMouseAt`: where the held button was pressed (0-1000), if held.
    static func decision(for answer: Answer, hasRoundsLeft: Bool = false, roundHasMoves: Bool = false, heldMouseAt: (centerX: Double, centerY: Double)? = nil) -> Decision {
        if hasRoundsLeft {
            if answer.move == .finishedRound { return roundHasMoves ? .roundDone : .unsure }
            if roundHasMoves, let doneProbability = answer.doneProbability, doneProbability >= doneProbabilityToFinish { return .roundDone }
            if answer.move == .finished { return .unsure }
        }
        if case .releaseMouseOn(_, let releaseX, let releaseY) = answer.move, let heldMouseAt,
           DottieMouseHoldPlan.releaseMovesTheHeldThing(heldX: heldMouseAt.centerX, heldY: heldMouseAt.centerY, releaseX: releaseX, releaseY: releaseY),
           answer.probability < minimumProbabilityForHardToUndoMoves {
            return .unsure
        }
        if !hasRoundsLeft, let doneProbability = answer.doneProbability, doneProbability >= doneProbabilityToFinish { return .finished }
        if answer.move == .finished {
            // Jev picking "done" while its own yes/no says no is a guess.
            if let doneProbability = answer.doneProbability, doneProbability < 0.5 { return .unsure }
            return .finished
        }
        if answer.move == .noneFits { return .unsure }
        if answer.confidence < minimumConfidence && answer.probability < minimumTopProbability { return .unsure }
        // Moves that are hard to take back need Jev to be clearly sure.
        if movesNeedingClearPick(answer.move), answer.probability < minimumProbabilityForHardToUndoMoves { return .unsure }
        return .act(answer.move)
    }

    /// Jev's pick must be at least this likely for a move that's hard to
    /// take back (a drag, closing or quitting, a right-click menu, a Mac action).
    static let minimumProbabilityForHardToUndoMoves = 0.5

    static func movesNeedingClearPick(_ move: Move) -> Bool {
        switch move {
        case .drag, .rightClick, .quickMacAction, .holdMouseDown: return true
        case .pressKeys(let keys, _): return DottieJevQuickCommands.isRisky(keys: keys)
        default: return false
        }
    }

    /// The step model's note when it takes over.
    static func handOverNote(movesSoFar: [String], reason: String) -> String {
        guard !movesSoFar.isEmpty else { return "" }
        return "Dottie already did these steps on screen: \(DottieJobMemory.compactList(movesSoFar)). \(reason) Carry on from the screen as it is now; don't redo them."
    }

    /// Vision's box (0-1, bottom-left origin) as a 0-1000 top-left middle.
    static func screenText(_ text: String, visionBox: CGRect) -> ScreenText {
        ScreenText(text: text, centerX: Double(visionBox.midX) * 1000, centerY: (1 - Double(visionBox.midY)) * 1000)
    }

    /// Two 32×18 gray thumbnails show the same screen.
    static func isSameScreen(_ first: [UInt8], _ second: [UInt8]) -> Bool {
        guard first.count == second.count, !first.isEmpty else { return false }
        var totalDifference = 0
        for index in first.indices {
            totalDifference += abs(Int(first[index]) - Int(second[index]))
        }
        return Double(totalDifference) / Double(first.count) < 4
    }

    // MARK: Helpers

    static func comparableWords(_ text: String) -> String {
        // One pass over the letters (this runs for every text on every
        // screen): runs of letters and digits joined by single spaces.
        var comparableScalars = String.UnicodeScalarView()
        var isBetweenWords = false
        let lettersAndDigits = CharacterSet.alphanumerics
        for scalar in text.lowercased().unicodeScalars {
            if lettersAndDigits.contains(scalar) {
                if isBetweenWords && !comparableScalars.isEmpty {
                    comparableScalars.append(" ")
                }
                isBetweenWords = false
                comparableScalars.append(scalar)
            } else {
                isBetweenWords = true
            }
        }
        return String(comparableScalars)
    }

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let fullRange = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: fullRange).compactMap { match in
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}

/// The running half: looks, asks Jev, acts, and keeps count.
@MainActor
enum DottieJevDriver {
    enum Outcome {
        case finished(stepCount: Int)
        case handedOver(note: String)
        case notTried
    }

    /// What the screen-job runner does for the driver, so clicks fly the
    /// cursor and sites open the way the rest of the job does.
    struct Actions {
        let progress: @MainActor (_ stepNumber: Int, _ line: String) -> Void
        let click: @MainActor (_ point: CGPoint, _ label: String, _ clickCount: Int, _ isRightClick: Bool, _ screen: DottieDisplayCapture.Screenshot, _ stepNumber: Int) async -> Void
        /// Points the mouse at something without clicking; the pointer stays there.
        let hover: @MainActor (_ point: CGPoint, _ label: String, _ screen: DottieDisplayCapture.Screenshot, _ stepNumber: Int) async -> Void
        /// `inSameTab`: replace the tab in front instead of opening another.
        let openSite: @MainActor (_ address: String, _ stepNumber: Int, _ inSameTab: Bool) async -> Void
    }

    private static let finishedCountKey = "DottieJevDriverFinishedCount"
    private static let handedOverCountKey = "DottieJevDriverHandedOverCount"

    /// How often Jev finished a job alone, for the log and Settings.
    static var aloneReport: String {
        let finishedCount = UserDefaults.standard.integer(forKey: finishedCountKey)
        let handedOverCount = UserDefaults.standard.integer(forKey: handedOverCountKey)
        return "Jev finished \(finishedCount) of \(finishedCount + handedOverCount) screen jobs alone"
    }

    /// What the last run did (moves, Jev and advisor calls, steps done from
    /// memory), for the screen job's report.
    private(set) static var lastRunStats = DottieJevRunStats()
    /// What the last run did, for keeping the job as a task when Claude
    /// finishes it after Jev handed over: the moves Jev recorded (round 1),
    /// the saved task's problem, and whether Jev already kept the task.
    private(set) static var lastRecording = DottieAppTaskRecording()
    private(set) static var lastPathProblem: DottieAppTaskProblem?
    private(set) static var lastRunKeptItsTask = false

    static func run(
        taskText: String, knownHowTo givenHowTo: String,
        startKnowledge: DottieAppTasks.JobStartKnowledge = .nothing, usesAppMemory: Bool = true,
        actions: Actions
    ) async -> Outcome {
        var knownHowTo = givenHowTo
        // App memory, looked up once as the job started (the memory trial can
        // turn it off): a saved task's steps are done again one by one while
        // they fit the screen, and its notes go to Jev and the advisor.
        let taskToReplay = usesAppMemory ? startKnowledge.taskToReplay : nil
        var pathReplay = taskToReplay.map { DottieAppTaskPathReplay(task: $0) }
        var pathProblem: DottieAppTaskProblem?
        var lastMoveCameFromSavedTask = false
        // Rounds 2 to N of a repeated job: round 1's own steps done again
        // with that round's details (DottieRoundReplayPlan), not a saved task.
        var pathReplayIsRoundRecipe = false
        // The task's own notes go first, so the cut at 4,500 characters
        // drops the general lessons rather than them (the watch me review).
        if usesAppMemory, !startKnowledge.taskText.isEmpty {
            knownHowTo = startKnowledge.taskText + "\n" + knownHowTo
        }
        // Every move that changed the screen, kept as a named task when Jev finishes.
        var recording = DottieAppTaskRecording()
        var lastRecordedMoveSignature: String?
        // Kept once per job: after round 1 of a repeated job, or at the finish.
        var taskWasKept = false
        var runStats = DottieJevRunStats(savedTaskSteps: taskToReplay?.steps.count ?? 0)
        let requestTextPieces = DottieJevDriverPlan.textPieces(from: taskText)
        var textPieces = requestTextPieces
        // The text a job needs typed, written once in the background while
        // Jev starts (DottieJevTextPieces); picked up as soon as it's ready.
        var textPieceWriter: Task<[String], Never>?
        if DottieJevTextPieces.jobNeedsTyping(taskText) {
            textPieceWriter = Task { await DottieJevTextPieces.write(forTask: taskText) }
        }
        let siteAddresses = DottieJevDriverPlan.siteAddresses(from: taskText)
        let appNames = appNamesNamed(in: taskText)
        var movesSoFar: [String] = []
        var triedSignaturesByScreen: [[UInt8]: Set<String>] = [:]
        var previousScreenThumbnail: [UInt8]?
        var lastMoveSignature: String?
        var movesWithoutChange = 0
        // App memory: the click this job made last, waiting to see which
        // page it opened, and the labels clicked so far (never twice from memory).
        var clickWaitingForResult: (bundleIdentifier: String, pageKey: String, label: String, centerX: Double, centerY: Double)?
        /// This job's clicks that changed nothing or didn't work, per page,
        /// waiting for the click that works there (the fix).
        var missedClickLabelsByPageKey: [String: [String]] = [:]
        var labelsClickedFromMemory = Set<String>()
        // Every move, and which round of a repeated job this is.
        var jobMemory = DottieJobMemory(taskText: taskText)
        // The advisor reads the task now, while Jev starts (DottieJevAdvisor),
        // and is asked again only when a step needs judging, waiting or reasoning.
        let advisor = DottieJevAdvisorSession(taskText: taskText, rounds: jobMemory.totalRounds,
                                              appKnowledge: usesAppMemory ? startKnowledge.fullText : "")
        // The last moves changed nothing: the advisor gets one go before the
        // job hands over, and another only once a move has changed the screen.
        var isStuck = false
        var screenChangedSinceStuckAdvice = true
        // The screen the advisor was asked on because Jev was unsure.
        var screenAdvisedWhileUnsure: [UInt8]?
        // Advice asked alongside Jev, used when it's back (never waited for).
        var adviceInFlight: DottieJevAdvisorSession.AdviceInFlight?
        // Waits don't use up Jev's steps.
        var waitsGiven = 0
        // Long jobs: every 100 moves the state goes to a file and starts again from it.
        var ledgerSlot: Int?
        var movesAtLastLedgerPage = 0
        var ledgerPageCount = 0
        // The button Jev pressed and hasn't let go of yet (0-1000).
        var heldMouse: (label: String, centerX: Double, centerY: Double)?
        // Clicks dropped in a row because their spot changed before the click.
        var staleMovesDroppedInARow = 0
        // Keys the user's hints name, offered first.
        var hintKeyMoves: [DottieJevDriverPlan.Move] = []
        // Step checks: the last move Jev made, the open moves that worked
        // this round (never offered again), moves Jev's check said failed
        // (struck off for the round, whatever the screen), and the hosts
        // this job opened (later pages there replace that tab).
        var lastMove: DottieJevDriverPlan.Move?
        var openedSignaturesThisRound = Set<String>()
        var failedSignaturesThisRound = Set<String>()
        var failedStepChecksInARow = 0
        var hostsOpenedByThisJob = Set<String>()
        // However this ends (finished, handed over, stopped), a held button is let go.
        defer { DottieMouseHold.releaseNow(reason: "the Jev part of the job ended") }
        defer {
            runStats.moves = jobMemory.totalMovesNoted
            // The brief, and every advice call this job made.
            runStats.advisorCalls = 1 + DottieJevAdvisorPlan.adviceCallBudget(rounds: jobMemory.totalRounds) - advisor.adviceCallsLeft
            lastRunStats = runStats
            lastRecording = recording
            lastPathProblem = pathProblem
            lastRunKeptItsTask = taskWasKept
        }

        func handOver(_ reason: String, jevPartWorked: Bool = false) -> Outcome {
            if let taskToReplay, !jevPartWorked {
                DottieAppTasks.shared.noteJevHandedOver(
                    request: taskText, replayedTaskID: taskToReplay.id,
                    problem: pathProblem ?? (pathReplayIsRoundRecipe ? nil : pathReplay?.problemWithCurrentStep("Jev handed the job over: \(reason)", now: Date()))
                )
            }
            UserDefaults.standard.set(UserDefaults.standard.integer(forKey: handedOverCountKey) + 1, forKey: handedOverCountKey)
            DottieLog.notice("🎯 Jev handed the screen job over after \(jobMemory.totalMovesNoted) moves (\(reason)); \(aloneReport)")
            var note = DottieJevDriverPlan.handOverNote(movesSoFar: movesSoFar, reason: reason)
            if jobMemory.isRepeatedJob { note += "\n" + jobMemory.stateText() }
            return .handedOver(note: note)
        }

        func noteDone(_ move: DottieJevDriverPlan.Move) {
            movesSoFar.append(move.summary)
            jobMemory.noteMove(move.summary)
        }

        /// A move made on the page `context` shows, kept as a step of the
        /// task (round 1 only: later rounds repeat it).
        func record(_ move: DottieJevDriverPlan.Move, context: DottieReplayContext) {
            guard jobMemory.currentRound == 1, let bundleIdentifier = context.appBundleIdentifier,
                  let step = DottieAppTaskPlan.step(from: move, pageTitle: context.windowTitle ?? "", requestText: taskText) else { return }
            recording.note(step, placeKey: DottieAppTaskPlan.placeKey(siteHost: context.siteHost, bundleIdentifier: bundleIdentifier),
                           placeName: context.siteHost ?? context.appName ?? bundleIdentifier, bundleIdentifier: bundleIdentifier)
            lastRecordedMoveSignature = move.signature
        }

        /// The saved steps stopped fitting: Jev carries on with a note.
        func dropSavedTask(_ problem: DottieAppTaskProblem, reason: String) {
            guard let activeReplay = pathReplay else { return }
            pathReplay = nil
            if pathReplayIsRoundRecipe {
                // Only this round goes to Jev: the next round tries round 1's steps again.
                pathReplayIsRoundRecipe = false
                movesSoFar.append("round 1's steps stopped fitting at step \(problem.stepNumber) (\(reason)); Jev does the rest of this round")
                DottieLog.notice("🔁 Round 1's steps stopped fitting at step \(public: problem.stepNumber) of \(activeReplay.task.name); Jev does the rest of it")
                return
            }
            pathProblem = problem
            knownHowTo += "\n" + activeReplay.noteForJev(reason: reason)
            DottieLog.notice("🗂️ A saved task stopped fitting the screen at step \(public: problem.stepNumber); Jev carries on")
        }

        /// The next round of a repeated job starts on round 1's own steps,
        /// with this round's details typed and clicked where round 1's were.
        func startRoundFromRoundOne() {
            guard jobMemory.currentRound >= 2,
                  let roundTask = DottieRoundReplayPlan.roundTask(
                      roundOneSteps: recording.steps, round: jobMemory.currentRound, totalRounds: jobMemory.totalRounds,
                      taskText: taskText, appName: recording.mainPlaceName ?? "", places: recording.places, now: Date()
                  ) else { return }
            pathReplay = DottieAppTaskPathReplay(task: roundTask)
            pathReplayIsRoundRecipe = true
            DottieLog.notice("🔁 Round \(public: jobMemory.currentRound) starts on round 1's \(public: roundTask.steps.count) steps, no Jev call per step")
        }

        /// Jev finished: the job is kept as a named task (or counted on its saved one).
        func keepFinishedTask() {
            guard !taskWasKept else { return }
            taskWasKept = true
            recording.finalPageTitle = DottieReplayContext.current().windowTitle
            DottieAppTasks.shared.noteJobFinished(request: taskText, matchedTaskID: startKnowledge.task?.id,
                                                  recording: recording, pathProblem: pathProblem)
        }

        /// The advisor named a spot that isn't one of Jev's options ("the
        /// empty box to the right of DOB"): Jev finds it on a fresh look,
        /// Dottie clicks it and types what the advisor said.
        func doWhatTheAdvisorPointedAt(_ description: String, typeText: String?, stepNumber: Int) async {
            let found = await clickDescribedThing(description, typeText: typeText, stepNumber: stepNumber, actions: actions)
            let summary = DottieJevAdvisorPlan.summaryOfPointedMove(description: description, typeText: typeText, wasFound: found)
            movesSoFar.append(summary)
            jobMemory.noteMove(summary)
            if found { await waitForScreenToSettle(opensSomethingNew: false) }
        }

        /// Asks the advisor and does the waiting it says; the caller does
        /// the move, looks again or hands over.
        func askAdvisor(
            _ trigger: DottieJevAdvisorPlan.Trigger, screenTexts: [DottieJevDriverPlan.ScreenText],
            options: [DottieJevDriverPlan.Option], stepNumber: Int
        ) async -> AdvisedStep {
            actions.progress(stepNumber, "thinking it over")
            let help = await advisor.help(
                trigger: trigger, screenTexts: screenTexts, options: options, jobStateText: jobMemory.stateText(),
                hasRoundsLeft: jobMemory.hasRoundsLeft, roundHasMoves: !jobMemory.movesThisRound.isEmpty
            )
            switch help {
            case .decision(let advisedDecision):
                return .useDecision(advisedDecision)
            case .wait(let seconds):
                waitsGiven += 1
                await waitWhileBusy(firstSeconds: seconds, advisor: advisor, stepNumber: stepNumber, actions: actions)
                return .lookAgain
            case .noted:
                return .lookAgain
            case .clickThing(let description, let typeText):
                await doWhatTheAdvisorPointedAt(description, typeText: typeText, stepNumber: stepNumber)
                return .lookAgain
            case .noHelp:
                return .handOverNow
            }
        }

        let stepBudget = DottieJevDriverPlan.stepBudget(rounds: jobMemory.totalRounds)
        var stepNumber = 0
        while stepNumber - waitsGiven < stepBudget {
            stepNumber += 1
            if Task.isCancelled { return .handedOver(note: "") }
            // A long job's memory goes to a file every 100 moves and the job
            // goes on from that file alone, so old details never pile up.
            if DottieJobLedger.isPageDue(totalMoves: jobMemory.totalMovesNoted, movesAtLastPage: movesAtLastLedgerPage) {
                ledgerPageCount += 1
                let slot = ledgerSlot ?? DottieJobLedger.takeSlotForNewJob()
                ledgerSlot = slot
                let page = DottieJobLedger.page(goal: taskText, pageNumber: ledgerPageCount, jobMemory: jobMemory, advisorNotes: advisor.notes)
                let savedPage = DottieJobLedger.saveAndReload(page, slot: slot) ?? page
                jobMemory = DottieJobMemory(ledgerPage: savedPage)
                advisor.restoreNotes(savedPage.advisorNotes)
                movesSoFar = DottieJobLedger.keptRecentMoves(movesSoFar)
                // Screens struck off long ago don't come back; the last one's moves stay struck off.
                triedSignaturesByScreen = triedSignaturesByScreen.filter { entry in
                    previousScreenThumbnail.map { DottieJevDriverPlan.isSameScreen(entry.key, $0) } ?? false
                }
                movesAtLastLedgerPage = jobMemory.totalMovesNoted
                DottieLog.notice("🗂️ Saved page \(public: ledgerPageCount) of a long screen job's memory after \(public: jobMemory.totalMovesNoted) moves; going on from it")
            }
            // Video players (YouTube's gear, captions, speed) show their
            // controls only while the mouse moves: a still screenshot never
            // had them. Never while a button is held, which would drag.
            if heldMouse == nil, DottieBrowser.isBrowser(bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) {
                await wakeHoverControls()
            }
            guard let screen = await DottieDisplayCapture.captureActiveDisplay(maximumDimension: DottieJevProtocol.maximumImageSide) else {
                return movesSoFar.isEmpty ? .notTried : handOver("The screen couldn't be read.")
            }
            let screenThumbnail = thumbnail(of: screen.image)
            // Exploring: a move that left the screen as it was is struck
            // off for that screen, so Jev's next best pick gets its turn.
            let screenLooksTheSame = previousScreenThumbnail.map { DottieJevDriverPlan.isSameScreen($0, screenThumbnail) } ?? false
            // Clicking into a text box barely changes the screen (a caret),
            // but it worked: it isn't struck off, dropped from the recording
            // or remembered as a miss (the speed review, 28 Nov: round 1
            // taught memory that its own good field clicks were wrong).
            let lastMoveWasAClick: Bool
            switch lastMove {
            case .some(.click), .some(.clickControl), .some(.doubleClick): lastMoveWasAClick = true
            default: lastMoveWasAClick = false
            }
            let lastClickFocusedATextBox = screenLooksTheSame && lastMoveWasAClick && DottieScreenActionPerformer.isTextFieldFocused
            let lastMoveChangedNothing = screenLooksTheSame && !lastClickFocusedATextBox
            // A key press can work without changing the screen (copy); any
            // other move that changed nothing isn't a step of the task, and a
            // saved step that changed nothing means the saved way went stale.
            let lastMoveWasKeyPress: Bool
            if case .some(.pressKeys(_, _)) = lastMove { lastMoveWasKeyPress = true } else { lastMoveWasKeyPress = false }
            if lastMoveChangedNothing, !lastMoveWasKeyPress, let lastMoveSignature {
                if lastRecordedMoveSignature == lastMoveSignature {
                    recording.dropLastStep()
                    lastRecordedMoveSignature = nil
                }
                if lastMoveCameFromSavedTask, let activeReplay = pathReplay {
                    dropSavedTask(activeReplay.problemWithStepJustDone("it changed nothing on the screen", now: Date()),
                                  reason: "its last step changed nothing on the screen")
                }
            }
            lastMoveCameFromSavedTask = false
            if lastMoveSignature != nil {
                // The user's hints learn whether the move they led to did anything.
                DottieScreenJobHints.shared.noteMove(changedScreen: !lastMoveChangedNothing)
            }
            // A hint from the user is a new way to try: what was struck off
            // and the moves that changed nothing start over.
            let newHints = DottieScreenJobHints.shared.takeNew()
            if !newHints.isEmpty {
                triedSignaturesByScreen = [:]
                movesWithoutChange = 0
                for newHint in newHints {
                    textPieces = DottieJevTextPieces.merged(DottieJevDriverPlan.textPieces(from: newHint.text), textPieces)
                    if let hintKeys = DottieScreenJobHintPlan.keyCombination(in: newHint.text) {
                        hintKeyMoves.insert(.pressKeys(keys: hintKeys, meaning: "the user said to"), at: 0)
                    }
                }
                actions.progress(stepNumber, "trying your way")
            } else if let previousScreenThumbnail, let lastMoveSignature, lastMoveChangedNothing {
                triedSignaturesByScreen[previousScreenThumbnail, default: []].insert(lastMoveSignature)
                movesWithoutChange += 1
                if movesWithoutChange >= DottieJevDriverPlan.maximumMovesWithoutChange {
                    guard heldMouse == nil, screenChangedSinceStuckAdvice, advisor.adviceCallsLeft > 0 else {
                        return handOver("The last moves didn't change the screen.")
                    }
                    isStuck = true
                    screenChangedSinceStuckAdvice = false
                    movesWithoutChange = 0
                }
            } else {
                movesWithoutChange = 0
                if lastMoveSignature != nil { screenChangedSinceStuckAdvice = true }
            }
            let screenKey = triedSignaturesByScreen.keys.first { DottieJevDriverPlan.isSameScreen($0, screenThumbnail) } ?? screenThumbnail

            let allScreenTexts = await readTexts(on: screen.image)
            let appMemory = DottieAppMemory.shared
            // The front app and window are read once per step: app memory
            // used to read them up to four times, walking a browser's whole
            // window for its address each time (the app memory review).
            let stepContext = DottieReplayContext.current()
            let frontPage = appMemory.frontPageForScreenJob(context: stepContext)
            let clickJustMade = clickWaitingForResult
            if let clickWaitingForResult, let frontPage,
               frontPage.key != clickWaitingForResult.pageKey {
                appMemory.noteClick(bundleIdentifier: clickWaitingForResult.bundleIdentifier, fromPageKey: clickWaitingForResult.pageKey,
                                    centerX: clickWaitingForResult.centerX, centerY: clickWaitingForResult.centerY,
                                    label: clickWaitingForResult.label, toPageKey: frontPage.key, toPageTitle: frontPage.title)
                // It led on after wrong clicks on that page: the fix is kept with them.
                if let missedLabels = missedClickLabelsByPageKey[clickWaitingForResult.pageKey], !missedLabels.isEmpty {
                    appMemory.noteFix(bundleIdentifier: clickWaitingForResult.bundleIdentifier, pageKey: clickWaitingForResult.pageKey,
                                      fixLabel: clickWaitingForResult.label, missedLabels: missedLabels)
                    missedClickLabelsByPageKey[clickWaitingForResult.pageKey] = nil
                }
            }
            // A click that changed the screen on its own page worked: an old
            // miss of it is forgiven.
            if let clickJustMade, !lastMoveChangedNothing, frontPage?.key == clickJustMade.pageKey {
                appMemory.forgiveMiss(bundleIdentifier: clickJustMade.bundleIdentifier, pageKey: clickJustMade.pageKey, label: clickJustMade.label)
            }
            // A click that changed nothing is remembered on its page, so the
            // next job doesn't make the same mistake.
            if let clickJustMade, lastMoveChangedNothing, (frontPage?.key ?? clickJustMade.pageKey) == clickJustMade.pageKey {
                appMemory.noteMiss(bundleIdentifier: clickJustMade.bundleIdentifier, pageKey: clickJustMade.pageKey,
                                   label: clickJustMade.label, centerX: clickJustMade.centerX, centerY: clickJustMade.centerY)
                missedClickLabelsByPageKey[clickJustMade.pageKey, default: []].append(clickJustMade.label)
            }
            clickWaitingForResult = nil
            let screenControls = readControls(onDisplay: screen.displayFrame)
            if let frontPage {
                appMemory.notePageFromScreenJob(on: frontPage, elements: allScreenTexts.map {
                    DottieAppPage.Element(label: $0.text, centerX: $0.centerX, centerY: $0.centerY)
                }, controls: screenControls.map {
                    DottieAppPage.Control(label: $0.label, kind: $0.kind, centerX: $0.centerX, centerY: $0.centerY)
                })
            }
            let knownPage = usesAppMemory ? frontPage.flatMap(appMemory.knownPage(for:)) : nil
            let screenTexts = DottieJevDriverPlan.clickableTexts(from: allScreenTexts, taskText: taskText)
            // Wait for the written text once a text box is on screen or
            // after the first move (pages whose boxes Accessibility doesn't
            // name); on the first screen there's usually nothing to type into.
            if let pendingWriter = textPieceWriter,
               stepNumber >= 2 || screenControls.contains(where: { $0.kind == "text box" }) || DottieScreenActionPerformer.isTextFieldFocused {
                textPieces = DottieJevTextPieces.merged(requestTextPieces, await pendingWriter.value)
                textPieceWriter = nil
            }

            // A saved task: its next step is done straight away while it fits
            // this screen; where it doesn't, Jev carries on with a note.
            if heldMouse == nil, var activeReplay = pathReplay, !activeReplay.jevIsDoingStep, let savedStep = activeReplay.currentStep {
                switch DottieAppTaskPlan.replayStep(
                    savedStep, recordedForRequest: activeReplay.task.stepsRecordedFor, newRequest: taskText,
                    screenTexts: allScreenTexts, screenControls: screenControls,
                    frontSiteHost: stepContext.siteHost, frontAppName: stepContext.appName
                ) {
                case .move(let savedMove):
                    let savedMoveTypes: Bool
                    switch savedMove {
                    case .typeText, .typeIntoField: savedMoveTypes = true
                    default: savedMoveTypes = false
                    }
                    // Never typed from memory into a password box.
                    if savedMoveTypes, DottieScreenActionPerformer.isFocusedFieldSecure {
                        dropSavedTask(activeReplay.problemWithCurrentStep("a password box was selected", now: Date()),
                                      reason: "a password box was selected")
                        break
                    }
                    activeReplay.advance()
                    pathReplay = activeReplay
                    runStats.replayedSteps += 1
                    if pathReplayIsRoundRecipe {
                        actions.progress(stepNumber, "\(activeReplay.task.name), step \(activeReplay.nextStepIndex) of \(activeReplay.task.steps.count) the way round 1 went")
                        DottieLog.notice("🔁 Did step \(public: activeReplay.nextStepIndex) of \(activeReplay.task.name) from round 1 without asking Jev")
                    } else {
                        actions.progress(stepNumber, "doing \"\(activeReplay.task.name)\" from memory, step \(activeReplay.nextStepIndex) of \(activeReplay.task.steps.count)")
                        DottieLog.notice("🗂️ Did step \(public: activeReplay.nextStepIndex) of a saved task without asking Jev")
                    }
                    await perform(savedMove, screen: screen, stepNumber: stepNumber, taskText: taskText, movesSoFar: movesSoFar, actions: actions,
                                  frontSiteHost: stepContext.siteHost, hostsOpenedByThisJob: hostsOpenedByThisJob)
                    // A later round typed into a box that stayed empty: the
                    // typing went nowhere, so the rest of the round is Jev's.
                    if pathReplayIsRoundRecipe, savedMoveTypes,
                       DottieRoundReplayPlan.typingWentNowhere(focusedFieldValue: DottieScreenActionPerformer.focusedTextFieldValue) {
                        dropSavedTask(activeReplay.problemWithStepJustDone("the box stayed empty after typing", now: Date()),
                                      reason: "the box stayed empty after typing")
                    }
                    if let openedHost = DottieJevDriverPlan.openedHost(of: savedMove) { hostsOpenedByThisJob.insert(openedHost) }
                    noteDone(savedMove)
                    record(savedMove, context: stepContext)
                    lastMove = savedMove
                    lastMoveCameFromSavedTask = true
                    previousScreenThumbnail = screenKey
                    lastMoveSignature = savedMove.signature
                    if case .click(let label, let centerX, let centerY) = savedMove, let frontPage {
                        clickWaitingForResult = (frontPage.bundleIdentifier, frontPage.key, label, centerX, centerY)
                    }
                    await waitForScreenToSettle(opensSomethingNew: savedMove.opensSomethingNew)
                    continue
                case .alreadyDone:
                    activeReplay.advance()
                    pathReplay = activeReplay
                    previousScreenThumbnail = nil
                    lastMoveSignature = nil
                    lastMove = nil
                    continue
                case .jevTakesIt:
                    activeReplay.jevIsDoingStep = true
                    pathReplay = activeReplay
                case .notOnScreen:
                    if !activeReplay.missedOnce {
                        // The page may still be drawing: one more look first.
                        activeReplay.missedOnce = true
                        pathReplay = activeReplay
                        previousScreenThumbnail = nil
                        lastMoveSignature = nil
                        lastMove = nil
                        await waitForScreenToSettle(maximumSeconds: 1.5)
                        continue
                    }
                    dropSavedTask(activeReplay.problemWithCurrentStep("it wasn't on the screen (on \"\(stepContext.windowTitle ?? "the page")\")", now: Date()),
                                  reason: "its next step (\(DottieAppTaskPlan.stepLine(savedStep))) wasn't on the screen")
                }
            }

            // Something clicked here before led where this task is going:
            // click it now (where it sits on this screen) without asking Jev.
            if heldMouse == nil, let knownPage,
               let rememberedClick = DottieAppMemoryPlan.rememberedClick(
                   on: knownPage, forTask: taskText,
                   visibleLabels: allScreenTexts.map(\.text), alreadyClickedLabels: labelsClickedFromMemory
               ),
               let visibleText = DottieLooseLabels.bestMatch(
                   forLabel: rememberedClick.label, role: nil, centerX: rememberedClick.centerX, centerY: rememberedClick.centerY,
                   among: allScreenTexts.map { DottieLooseLabels.Candidate(label: $0.text, role: nil, centerX: $0.centerX, centerY: $0.centerY) }
               ) {
                let move = DottieJevDriverPlan.Move.click(label: visibleText.label, centerX: visibleText.centerX, centerY: visibleText.centerY)
                labelsClickedFromMemory.insert(DottieAppMemoryPlan.comparableWords(rememberedClick.label))
                runStats.memoryClicks += 1
                DottieLog.notice("🎯 App memory clicked a remembered button without asking Jev")
                await perform(move, screen: screen, stepNumber: stepNumber, taskText: taskText, movesSoFar: movesSoFar, actions: actions,
                              frontSiteHost: nil, hostsOpenedByThisJob: hostsOpenedByThisJob)
                noteDone(move)
                record(move, context: stepContext)
                lastMove = move
                previousScreenThumbnail = screenKey
                lastMoveSignature = move.signature
                if let frontPage {
                    clickWaitingForResult = (frontPage.bundleIdentifier, frontPage.key, visibleText.label, visibleText.centerX, visibleText.centerY)
                }
                await waitForScreenToSettle(opensSomethingNew: move.opensSomethingNew)
                continue
            }
            let alreadyTriedSignatures = (triedSignaturesByScreen[screenKey] ?? [])
                .union(openedSignaturesThisRound).union(failedSignaturesThisRound)
            let frontSiteHost = stepContext.siteHost
            let frontAppBundleIdentifier = stepContext.appBundleIdentifier
            let builtOptions = heldMouse.map { heldMouse in
                DottieJevDriverPlan.optionsWhileHoldingMouse(heldLabel: heldMouse.label, screenTexts: screenTexts,
                                                             screenControls: screenControls, alreadyTriedSignatures: alreadyTriedSignatures)
            } ?? DottieJevDriverPlan.options(
                screenTexts: screenTexts,
                textPieces: textPieces,
                siteAddresses: siteAddresses,
                appNames: appNames,
                alreadyTriedSignatures: alreadyTriedSignatures,
                frontSiteHost: frontSiteHost,
                screenControls: screenControls,
                taskText: taskText,
                // Remembered clicks are noted on Jev's own options below
                // instead of a page of text it couldn't use.
                offersAppMemory: false,
                offersNextRound: jobMemory.hasRoundsLeft && !jobMemory.movesThisRound.isEmpty,
                extraLeadingMoves: hintKeyMoves,
                isBrowserInFront: DottieBrowser.isBrowser(bundleIdentifier: frontAppBundleIdentifier),
                frontAppBundleIdentifier: frontAppBundleIdentifier
            )
            // Remembered clicks say what they opened; past misses are struck
            // off or say what worked instead.
            let options = knownPage.map {
                DottieAppMemoryPlan.optionsNotingMisses(DottieAppMemoryPlan.optionsNotingRememberedClicks(builtOptions, on: $0), on: $0, now: Date())
            } ?? builtOptions
            // The advisor steps in before Jev only when this step needs it: the
            // job is stuck, the user just said something, a time shows on
            // screen, or a moment the advisor's brief named is here.
            var advisedDecision: DottieJevDriverPlan.Decision?
            // Advice asked alongside Jev on an earlier step, if it's back.
            if let arrivedAdvice = adviceInFlight, let arrivedHelp = arrivedAdvice.help {
                adviceInFlight = nil
                let askedOnSameScreen = DottieJevDriverPlan.isSameScreen(arrivedAdvice.askedOnScreen, screenThumbnail)
                switch DottieJevAdvisorPlan.use(of: arrivedHelp, askedOnSameScreen: askedOnSameScreen, currentOptions: options) {
                case .decision(let decisionFromAdvisor) where heldMouse == nil:
                    DottieLog.notice("🧭 Using the advice that came back while Jev went on")
                    advisedDecision = decisionFromAdvisor
                case .wait(let seconds):
                    waitsGiven += 1
                    await waitWhileBusy(firstSeconds: seconds, advisor: advisor, stepNumber: stepNumber, actions: actions)
                    previousScreenThumbnail = nil
                    lastMoveSignature = nil
                    lastMove = nil
                    continue
                case .clickThing(let description, let typeText) where heldMouse == nil:
                    await doWhatTheAdvisorPointedAt(description, typeText: typeText, stepNumber: stepNumber)
                    previousScreenThumbnail = nil
                    lastMoveSignature = nil
                    lastMove = nil
                    continue
                default:
                    break
                }
            }
            if advisedDecision == nil, heldMouse == nil, let trigger = advisor.triggerBeforeJev(
                screenTexts: allScreenTexts.map(\.text), newHintTexts: newHints.map(\.text), isStuck: isStuck
            ) {
                if !DottieJevAdvisorPlan.mustWaitForAdvice(trigger) {
                    // Judging, waiting and the user's hints are thought over
                    // alongside Jev: Jev makes this step's move now, and the
                    // advice is used on a later step if it still fits.
                    if adviceInFlight == nil {
                        adviceInFlight = advisor.helpInBackground(
                            trigger: trigger, askedOnScreen: screenThumbnail, screenTexts: allScreenTexts, options: options,
                            jobStateText: jobMemory.stateText(), hasRoundsLeft: jobMemory.hasRoundsLeft,
                            roundHasMoves: !jobMemory.movesThisRound.isEmpty
                        )
                    }
                } else {
                    // Stuck: the job would hand over otherwise, so this one is worth the wait.
                    let wasStuck = isStuck
                    isStuck = false
                    switch await askAdvisor(trigger, screenTexts: allScreenTexts, options: options, stepNumber: stepNumber) {
                    case .useDecision(let decisionFromAdvisor):
                        advisedDecision = decisionFromAdvisor
                    case .lookAgain:
                        // Waited, or left Jev a note: look again before Jev picks.
                        previousScreenThumbnail = nil
                        lastMoveSignature = nil
                        lastMove = nil
                        continue
                    case .handOverNow:
                        // No help: a stuck job hands over, any other step goes on with Jev.
                        if wasStuck { return handOver("The last moves didn't change the screen.") }
                    }
                }
            }
            let answer: DottieJevDriverPlan.Answer?
            if advisedDecision == nil {
                let advisorHowTo = advisor.howToText
                let requestBody = DottieJevDriverPlan.requestBody(
                    goal: taskText, movesSoFar: movesSoFar, knownHowTo: advisorHowTo.isEmpty ? knownHowTo : advisorHowTo + "\n" + knownHowTo,
                    options: options, jobMemory: jobMemory, hintsText: DottieScreenJobHints.shared.stateText,
                    isHoldingMouse: heldMouse != nil, lastMoveSummary: lastMove?.summary
                )
                runStats.jevCalls += 1
                guard let answerData = await DottieJev.answer(to: requestBody, screenImage: screen.image),
                      let jevAnswer = DottieJevDriverPlan.answer(fromAnswer: answerData, options: options) else {
                    return movesSoFar.isEmpty ? .notTried : handOver("Jev didn't answer.")
                }
                answer = jevAnswer
            } else {
                answer = nil
            }
            if Task.isCancelled { return .handedOver(note: "") }

            var decision: DottieJevDriverPlan.Decision
            if let advisedDecision {
                decision = advisedDecision
            } else if let answer {
                // Jev's step check of the last move, from this same answer.
                if let checkedMove = lastMove {
                    if DottieJevDriverPlan.lastMoveFailed(answer, screenChangedAfterMove: !lastMoveChangedNothing) {
                        failedStepChecksInARow += 1
                        failedSignaturesThisRound.insert(checkedMove.signature)
                        // A click that changed the screen but didn't work, on
                        // the same page, is a miss to remember too.
                        if let clickJustMade, !lastMoveChangedNothing, frontPage?.key == clickJustMade.pageKey {
                            appMemory.noteMiss(bundleIdentifier: clickJustMade.bundleIdentifier, pageKey: clickJustMade.pageKey,
                                               label: clickJustMade.label, centerX: clickJustMade.centerX, centerY: clickJustMade.centerY)
                            missedClickLabelsByPageKey[clickJustMade.pageKey, default: []].append(clickJustMade.label)
                        }
                        openedSignaturesThisRound.remove(checkedMove.signature)
                        if lastRecordedMoveSignature == checkedMove.signature {
                            recording.dropLastStep()
                            lastRecordedMoveSignature = nil
                        }
                        if let lastIndex = movesSoFar.indices.last { movesSoFar[lastIndex] += " (Jev's check: it didn't work)" }
                        DottieLog.notice("🎯 Jev's step check: the last move didn't work")
                        if failedStepChecksInARow >= DottieJevDriverPlan.maximumFailedStepChecks {
                            // The advisor's go before handing over.
                            switch await askAdvisor(.moveFailed, screenTexts: allScreenTexts, options: options, stepNumber: stepNumber) {
                            case .useDecision(let decisionFromAdvisor):
                                failedStepChecksInARow = 0
                                advisedDecision = decisionFromAdvisor
                            case .lookAgain:
                                failedStepChecksInARow = DottieJevDriverPlan.maximumFailedStepChecks - 1
                                lastMove = nil
                                previousScreenThumbnail = nil
                                lastMoveSignature = nil
                                continue
                            case .handOverNow:
                                return handOver("Jev's step check said the last \(failedStepChecksInARow) moves didn't work.")
                            }
                        }
                        // The move Jev just picked was chosen on the same look:
                        // ask again next step with the failed move struck off.
                        if advisedDecision == nil, case .act(let pickedMove) = DottieJevDriverPlan.decision(for: answer),
                           pickedMove.signature == checkedMove.signature {
                            lastMove = nil
                            previousScreenThumbnail = nil
                            lastMoveSignature = nil
                            continue
                        }
                    } else {
                        failedStepChecksInARow = 0
                    }
                }
                decision = advisedDecision ?? DottieJevDriverPlan.decision(
                    for: answer, hasRoundsLeft: jobMemory.hasRoundsLeft, roundHasMoves: !jobMemory.movesThisRound.isEmpty,
                    heldMouseAt: heldMouse.map { (centerX: $0.centerX, centerY: $0.centerY) }
                )
            } else {
                return handOver("Jev didn't answer.")
            }
            // Jev unsure: the advisor's go before handing over, once per screen.
            if decision == .unsure, heldMouse == nil,
               !(screenAdvisedWhileUnsure.map { DottieJevDriverPlan.isSameScreen($0, screenKey) } ?? false) {
                screenAdvisedWhileUnsure = screenKey
                switch await askAdvisor(.jevUnsure, screenTexts: allScreenTexts, options: options, stepNumber: stepNumber) {
                case .useDecision(let decisionFromAdvisor):
                    decision = decisionFromAdvisor
                case .lookAgain:
                    previousScreenThumbnail = nil
                    lastMoveSignature = nil
                    lastMove = nil
                    continue
                case .handOverNow:
                    break
                }
            }
            switch decision {
            case .roundDone:
                // The next round starts like a fresh job on whatever screen
                // this one left: nothing is struck off from the last round.
                DottieMouseHold.releaseNow(reason: "a round ended")
                heldMouse = nil
                // Round 1 worked: it's the task's recipe, kept now so a
                // long job that stops later still teaches Dottie the task.
                if jobMemory.currentRound == 1 { keepFinishedTask() }
                jobMemory.finishRound()
                advisor.startRound()
                startRoundFromRoundOne()
                triedSignaturesByScreen = [:]
                movesWithoutChange = 0
                labelsClickedFromMemory = []
                previousScreenThumbnail = nil
                lastMoveSignature = nil
                lastMove = nil
                openedSignaturesThisRound = []
                failedSignaturesThisRound = []
                failedStepChecksInARow = 0
                movesSoFar.append("finished round \(jobMemory.currentRound - 1) of \(jobMemory.totalRounds)")
                DottieLog.notice("🎯 Jev finished round \(jobMemory.currentRound - 1) of \(jobMemory.totalRounds)")
                actions.progress(stepNumber, "round \(jobMemory.currentRound) of \(jobMemory.totalRounds)")
            case .finished:
                keepFinishedTask()
                if DottieJevDriverPlan.asksForInformation(taskText) {
                    return handOver("The screen should now show what the user asked about: read it and finish with the answer.", jevPartWorked: true)
                }
                UserDefaults.standard.set(UserDefaults.standard.integer(forKey: finishedCountKey) + 1, forKey: finishedCountKey)
                DottieLog.notice("🎯 Jev finished the screen job alone in \(jobMemory.totalMovesNoted) moves; \(aloneReport)")
                return .finished(stepCount: jobMemory.totalMovesNoted)
            case .unsure:
                return movesSoFar.isEmpty ? .notTried : handOver("Jev wasn't sure what comes next.")
            case .act(.recallAppMemory):
                actions.progress(stepNumber, "remembering how this app works")
                let rememberedText = await appMemory.recall(forTask: taskText, readsPageClosely: true)
                if !rememberedText.isEmpty { knownHowTo += "\n" + rememberedText }
                noteDone(.recallAppMemory)
                // Nothing on screen changed on purpose: not a move to strike off.
                previousScreenThumbnail = nil
                lastMoveSignature = nil
                lastMove = nil
            case .act(let move):
                if case .typeText = move, DottieScreenActionPerformer.isFocusedFieldSecure {
                    return handOver("A password box is selected.")
                }
                // The page may have moved while Jev thought: a click picked on
                // the old screen would land on whatever is there now.
                if let aimedPoint = move.aimedPoint,
                   DottieScreenSettle.shouldDropStaleMove(
                       targetRegionChanged: await targetRegionChanged(
                           around: aimedPoint, pickedOn: screen.image,
                           wakesHoverControls: heldMouse == nil && DottieBrowser.isBrowser(bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
                       ),
                       staleMovesDroppedInARow: staleMovesDroppedInARow
                   ) {
                    staleMovesDroppedInARow += 1
                    DottieLog.notice("🎯 The screen changed under Jev's click before it was made; looking again")
                    actions.progress(stepNumber, "the page moved, looking again")
                    // Not a move that changed nothing: nothing was done.
                    previousScreenThumbnail = nil
                    lastMoveSignature = nil
                    lastMove = nil
                    await waitForScreenToSettle(maximumSeconds: 2)
                    continue
                }
                staleMovesDroppedInARow = 0
                await perform(move, screen: screen, stepNumber: stepNumber, taskText: taskText, movesSoFar: movesSoFar, actions: actions,
                              frontSiteHost: frontSiteHost, hostsOpenedByThisJob: hostsOpenedByThisJob)
                if DottieJevDriverPlan.opensOnlyOnce(move) {
                    openedSignaturesThisRound.insert(move.signature)
                }
                if let openedHost = DottieJevDriverPlan.openedHost(of: move) {
                    hostsOpenedByThisJob.insert(openedHost)
                }
                lastMove = move
                switch move {
                case .holdMouseDown(let label, let centerX, let centerY): heldMouse = DottieMouseHold.isHolding ? (label, centerX, centerY) : nil
                case .releaseMouseHere, .releaseMouseOn: heldMouse = nil
                default: break
                }
                noteDone(move)
                record(move, context: stepContext)
                // Jev took a saved step it was asked to: the saved steps go on
                // when its move was that step, else Jev carries on alone.
                if let activeReplay = pathReplay, activeReplay.jevIsDoingStep, let savedStep = activeReplay.currentStep {
                    if DottieAppTaskPathReplay.jevMoveIsTheStep(move, step: savedStep, requestText: taskText) {
                        var advancedReplay = activeReplay
                        advancedReplay.advance()
                        pathReplay = advancedReplay
                    } else {
                        dropSavedTask(activeReplay.problemWithCurrentStep("Jev did something else instead: \(move.summary)", now: Date()),
                                      reason: "Jev did something else at that step")
                    }
                }
                previousScreenThumbnail = screenKey
                lastMoveSignature = move.signature
                if case .click(let label, let centerX, let centerY) = move, let frontPage {
                    clickWaitingForResult = (frontPage.bundleIdentifier, frontPage.key, label, centerX, centerY)
                }
                // Let the app draw what the move opened before looking again:
                // a page still loading looked like "nothing changed" and the
                // move was struck off.
                await waitForScreenToSettle(opensSomethingNew: move.opensSomethingNew)
            }
        }
        return handOver("Jev used its step budget.")
    }

    /// What the driver does after asking the advisor.
    private enum AdvisedStep {
        case useDecision(DottieJevDriverPlan.Decision)
        /// It waited or left Jev a note: look at the screen again.
        case lookAgain
        case handOverNow
    }

    /// Finds the thing the advisor described on a fresh look (Jev's box,
    /// sharpened on a close-up when small), clicks its middle and types the
    /// advisor's text into it. False when Jev couldn't find it.
    private static func clickDescribedThing(_ description: String, typeText: String?, stepNumber: Int, actions: Actions) async -> Bool {
        actions.progress(stepNumber, "finding \(description.prefix(50))")
        guard let screen = await DottieDisplayCapture.captureActiveDisplay(maximumDimension: DottieJevProtocol.maximumImageSide),
              let jevBox = await DottieJev.findPreciseBox(target: description, on: screen) else {
            DottieLog.notice("🧭 Jev couldn't find what the advisor pointed at")
            return false
        }
        let normalizedBox = jevBox.normalizedBox
        let middlePoint = screen.globalPoint(normalizedX: (normalizedBox.xmin + normalizedBox.xmax) / 2,
                                             normalizedY: (normalizedBox.ymin + normalizedBox.ymax) / 2)
        await actions.click(middlePoint, description, 1, false, screen, stepNumber)
        if let typeText, !typeText.isEmpty {
            try? await Task.sleep(nanoseconds: 250_000_000)
            actions.progress(stepNumber, "typing \"\(typeText.prefix(40))\"")
            await DottieScreenActionPerformer.type(typeText)
        }
        return true
    }

    /// Waits while something on screen is busy, without using Jev's steps
    /// (Wasee, 27 Nov): the time the advisor or the screen gives, then a new
    /// look; while the screen still shows a time left, it waits that long
    /// again, else the job goes on and Jev checks whether it's done. A round
    /// waits 30 minutes at most in all; Stop ends a wait at once.
    private static func waitWhileBusy(firstSeconds: Int, advisor: DottieJevAdvisorSession, stepNumber: Int, actions: Actions) async {
        var nextWaitSeconds = firstSeconds
        while !Task.isCancelled {
            let allowedSeconds = advisor.allowedWait(nextWaitSeconds)
            guard allowedSeconds > 0 else {
                DottieLog.notice("🧭 This round has waited as long as it may; going on")
                return
            }
            actions.progress(stepNumber, "waiting \(DottieJevAdvisorPlan.waitText(seconds: allowedSeconds)), then looking again")
            DottieLog.notice("🧭 Waiting \(public: allowedSeconds) s for the screen, then looking again")
            try? await Task.sleep(nanoseconds: UInt64(allowedSeconds) * 1_000_000_000)
            advisor.noteWaited(allowedSeconds)
            guard !Task.isCancelled,
                  let look = await DottieDisplayCapture.captureActiveDisplay(maximumDimension: DottieJevProtocol.maximumImageSide) else { return }
            let lookTexts = await readTexts(on: look.image).map(\.text)
            guard let shownSeconds = DottieJevAdvisorPlan.secondsShown(in: lookTexts) else { return }
            nextWaitSeconds = DottieJevAdvisorPlan.waitSeconds(shownSeconds: shownSeconds)
        }
    }

    /// Waits until the page has finished: the browser (when it says) has
    /// loaded the page and two looks in a row matched the one before.
    /// One match let a page that hadn't started drawing pass, and Jev
    /// pressed keys before a video had loaded (Wasee's tests, 27 Nov).
    private static func waitForScreenToSettle(opensSomethingNew: Bool) async {
        let startedAt = Date()
        try? await Task.sleep(nanoseconds: UInt64(DottieScreenSettle.firstLookDelaySeconds * 1_000_000_000))
        var lastThumbnail: [UInt8]?
        var matchingLooksInARow = 0
        while !Task.isCancelled {
            let pageLoad = frontWebPageLoad()
            let maximumSeconds = DottieScreenSettle.maximumWaitSeconds(opensSomethingNew: opensSomethingNew, pageLoad: pageLoad)
            guard Date().timeIntervalSince(startedAt) < maximumSeconds else { return }
            guard let look = await DottieDisplayCapture.captureActiveDisplay(maximumDimension: 320) else { return }
            let lookThumbnail = thumbnail(of: look.image)
            if let lastThumbnail, DottieJevDriverPlan.isSameScreen(lastThumbnail, lookThumbnail) {
                matchingLooksInARow += 1
            } else {
                matchingLooksInARow = 0
            }
            if DottieScreenSettle.isSettled(matchingLooksInARow: matchingLooksInARow, pageLoad: pageLoad) { return }
            lastThumbnail = lookThumbnail
            try? await Task.sleep(nanoseconds: UInt64(DottieScreenSettle.secondsBetweenLooks * 1_000_000_000))
        }
    }

    /// The old fixed-time wait, for the places that only know a time.
    private static func waitForScreenToSettle(maximumSeconds: Double) async {
        let startedAt = Date()
        var lastThumbnail: [UInt8]?
        var matchingLooksInARow = 0
        while Date().timeIntervalSince(startedAt) < maximumSeconds, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(DottieScreenSettle.secondsBetweenLooks * 1_000_000_000))
            guard let look = await DottieDisplayCapture.captureActiveDisplay(maximumDimension: 320) else { return }
            let lookThumbnail = thumbnail(of: look.image)
            if let lastThumbnail, DottieJevDriverPlan.isSameScreen(lastThumbnail, lookThumbnail) {
                matchingLooksInARow += 1
            } else {
                matchingLooksInARow = 0
            }
            if DottieScreenSettle.isSettled(matchingLooksInARow: matchingLooksInARow, pageLoad: .unknown) { return }
            lastThumbnail = lookThumbnail
        }
    }

    /// Whether the browser in front says its page finished loading, read
    /// from its web area through Accessibility. Bounded: a slow app answers
    /// "unknown" and the screen check alone decides.
    private static func frontWebPageLoad() -> DottieScreenSettle.PageLoad {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              DottieBrowser.isBrowser(bundleIdentifier: frontmostApplication.bundleIdentifier) else { return .unknown }
        let applicationElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)
        var focusedWindowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(applicationElement, kAXFocusedWindowAttribute as CFString, &focusedWindowValue) == .success,
              let focusedWindow = DottieAccessibilityCast.element(focusedWindowValue) else { return .unknown }
        let deadline = Date().addingTimeInterval(0.15)
        var elementsToVisit: [(element: AXUIElement, depth: Int)] = [(focusedWindow, 0)]
        var visitedCount = 0
        while !elementsToVisit.isEmpty, visitedCount < 300, Date() < deadline {
            let next = elementsToVisit.removeFirst()
            visitedCount += 1
            var roleValue: CFTypeRef?
            AXUIElementCopyAttributeValue(next.element, kAXRoleAttribute as CFString, &roleValue)
            if (roleValue as? String) == "AXWebArea" {
                var loadedValue: CFTypeRef?
                var progressValue: CFTypeRef?
                AXUIElementCopyAttributeValue(next.element, "AXLoaded" as CFString, &loadedValue)
                AXUIElementCopyAttributeValue(next.element, "AXLoadingProgress" as CFString, &progressValue)
                return DottieScreenSettle.pageLoad(loadedAttribute: (loadedValue as? NSNumber)?.boolValue,
                                                   loadingProgress: (progressValue as? NSNumber)?.doubleValue)
            }
            guard next.depth < 12 else { continue }
            var childrenValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(next.element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
               let childElements = childrenValue as? [AXUIElement] {
                elementsToVisit.append(contentsOf: childElements.map { ($0, next.depth + 1) })
            }
        }
        return .unknown
    }

    /// Nudges the mouse two points and back, so players that hide their
    /// controls while the mouse is still show them for the next look.
    private static func wakeHoverControls() async {
        guard let mouseLocation = CGEvent(source: nil)?.location else { return }
        for point in [CGPoint(x: mouseLocation.x + 2, y: mouseLocation.y), mouseLocation] {
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        // The controls fade in: give them a moment before the screenshot.
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    /// Whether the spot a move aims at looks different now from the
    /// screenshot Jev picked the move on.
    private static func targetRegionChanged(around aimedPoint: (centerX: Double, centerY: Double), pickedOn pickedImage: CGImage,
                                            wakesHoverControls: Bool) async -> Bool {
        // Jev picked on a screen with the player's controls showing; they
        // fade while it thinks, which isn't the page moving.
        if wakesHoverControls { await wakeHoverControls() }
        guard let now = await DottieDisplayCapture.captureActiveDisplay(maximumDimension: 800) else { return false }
        let pickedRegion = regionThumbnail(of: pickedImage, centerX: aimedPoint.centerX, centerY: aimedPoint.centerY)
        let nowRegion = regionThumbnail(of: now.image, centerX: aimedPoint.centerX, centerY: aimedPoint.centerY)
        return DottieScreenSettle.targetRegionChanged(pickedOn: pickedRegion, now: nowRegion)
    }

    /// The square around a point (0-1 of the image), shrunk to a small grey picture.
    private static func regionThumbnail(of image: CGImage, centerX: Double, centerY: Double) -> [UInt8] {
        let region = DottieScreenSettle.targetRegion(centerX: centerX, centerY: centerY, imageWidth: image.width, imageHeight: image.height)
        guard region.width > 0, let croppedImage = image.cropping(to: region) else { return [] }
        let side = DottieScreenSettle.targetRegionSide
        var pixels = [UInt8](repeating: 0, count: side * side)
        let didDraw = pixels.withUnsafeMutableBytes { pixelBuffer -> Bool in
            guard let context = CGContext(
                data: pixelBuffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.draw(croppedImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return didDraw ? pixels : []
    }

    private static func perform(_ move: DottieJevDriverPlan.Move, screen: DottieDisplayCapture.Screenshot, stepNumber: Int, taskText: String, movesSoFar: [String], actions: Actions,
                                frontSiteHost: String?, hostsOpenedByThisJob: Set<String>) async {
        /// An OCR text's middle, moved onto the real control under it.
        func snappedPoint(centerX: Double, centerY: Double) -> CGPoint {
            let roughPoint = screen.globalPoint(normalizedX: centerX, normalizedY: centerY)
            let snappedFrame = AccessibilitySnap.refinedFrame(CGRect(x: roughPoint.x - 2, y: roughPoint.y - 2, width: 4, height: 4))
            return CGPoint(x: snappedFrame.midX, y: snappedFrame.midY)
        }
        switch move {
        case .click(let label, let centerX, let centerY):
            await actions.click(snappedPoint(centerX: centerX, centerY: centerY), label, 1, false, screen, stepNumber)
        case .clickControl(let label, _, let centerX, let centerY):
            // Accessibility gave the control's own frame: already exact.
            await actions.click(screen.globalPoint(normalizedX: centerX, normalizedY: centerY), label, 1, false, screen, stepNumber)
        case .clickUnlabeled:
            actions.progress(stepNumber, "finding the icon to click")
            let target = "the icon, picture or button to click next so that this gets done: \(taskText.prefix(200))"
            let context = movesSoFar.isEmpty ? nil : "Done so far: " + movesSoFar.suffix(6).joined(separator: "; ")
            guard let jevBox = await DottieJev.findPreciseBox(target: target, userContext: context, on: screen) else { return }
            let normalizedBox = jevBox.normalizedBox
            let middlePoint = screen.globalPoint(normalizedX: (normalizedBox.xmin + normalizedBox.xmax) / 2, normalizedY: (normalizedBox.ymin + normalizedBox.ymax) / 2)
            await actions.click(middlePoint, "the icon", 1, false, screen, stepNumber)
        case .doubleClick(let label, let centerX, let centerY):
            await actions.click(snappedPoint(centerX: centerX, centerY: centerY), label, 2, false, screen, stepNumber)
        case .rightClick(let label, let centerX, let centerY):
            await actions.click(snappedPoint(centerX: centerX, centerY: centerY), label, 1, true, screen, stepNumber)
        case .hover(let label, let centerX, let centerY):
            await actions.hover(snappedPoint(centerX: centerX, centerY: centerY), label, screen, stepNumber)
        case .drag(let fromLabel, let fromX, let fromY, let toLabel, let toX, let toY):
            actions.progress(stepNumber, "dragging \(fromLabel) onto \(toLabel)")
            await DottieScreenActionPerformer.drag(from: snappedPoint(centerX: fromX, centerY: fromY), to: screen.globalPoint(normalizedX: toX, normalizedY: toY))
        case .pressKeys(let keys, _):
            actions.progress(stepNumber, "pressing \(keys)")
            DottieScreenActionPerformer.press(keyCombination: keys)
        case .scrollLeft, .scrollRight:
            let direction: DottieScreenAction.ScrollDirection = move == .scrollLeft ? .left : .right
            actions.progress(stepNumber, "scrolling \(direction.rawValue)")
            DottieScreenActionPerformer.scroll(direction: direction, amount: 5, at: screen.globalPoint(normalizedX: 500, normalizedY: 550))
        case .quickMacAction(let text):
            actions.progress(stepNumber, "doing it on the Mac")
            _ = await DottieQuickMacAction.perform(arguments: ["action": text])
        case .recallAppMemory, .finishedRound:
            break
        case .holdMouseDown(let label, let centerX, let centerY):
            actions.progress(stepNumber, "holding the mouse on \(label)")
            await DottieMouseHold.press(at: snappedPoint(centerX: centerX, centerY: centerY))
        case .releaseMouseHere:
            actions.progress(stepNumber, "letting go of the mouse")
            await DottieMouseHold.release(at: nil)
        case .releaseMouseOn(let label, let centerX, let centerY):
            actions.progress(stepNumber, "letting go on \(label)")
            await DottieMouseHold.release(at: screen.globalPoint(normalizedX: centerX, normalizedY: centerY))
        case .typeIntoField(let fieldLabel, let centerX, let centerY, let text, let pressesReturn):
            await actions.click(screen.globalPoint(normalizedX: centerX, normalizedY: centerY), fieldLabel, 1, false, screen, stepNumber)
            try? await Task.sleep(nanoseconds: 250_000_000)
            if DottieScreenActionPerformer.isFocusedFieldSecure { return }
            actions.progress(stepNumber, "typing \"\(text.prefix(40))\"")
            await DottieScreenActionPerformer.type(text)
            if pressesReturn {
                try? await Task.sleep(nanoseconds: 150_000_000)
                DottieScreenActionPerformer.press(keyCombination: "enter")
            }
        case .typeText(let text, let pressesReturn):
            actions.progress(stepNumber, "typing \"\(text.prefix(40))\"")
            await DottieScreenActionPerformer.type(text)
            if pressesReturn {
                try? await Task.sleep(nanoseconds: 150_000_000)
                DottieScreenActionPerformer.press(keyCombination: "enter")
            }
        case .pressReturn:
            actions.progress(stepNumber, "pressing Return")
            DottieScreenActionPerformer.press(keyCombination: "enter")
        case .scrollDown, .scrollUp:
            let direction: DottieScreenAction.ScrollDirection = move == .scrollDown ? .down : .up
            actions.progress(stepNumber, "scrolling \(direction.rawValue)")
            DottieScreenActionPerformer.scroll(direction: direction, amount: 5, at: screen.globalPoint(normalizedX: 500, normalizedY: 550))
        case .goBack:
            actions.progress(stepNumber, "going back")
            DottieScreenActionPerformer.press(keyCombination: "cmd+[")
        case .openSite(let address):
            let inSameTab = DottieJevDriverPlan.opensInSameTab(address: address, frontSiteHost: frontSiteHost, hostsOpenedByThisJob: hostsOpenedByThisJob)
            await actions.openSite(address, stepNumber, inSameTab)
        case .searchWeb(let text):
            let searchAddress = DottieJevDriverPlan.searchAddress(for: text)
            let inSameTab = DottieJevDriverPlan.opensInSameTab(address: searchAddress, frontSiteHost: frontSiteHost, hostsOpenedByThisJob: hostsOpenedByThisJob)
            await actions.openSite(searchAddress, stepNumber, inSameTab)
        case .openApp(let name):
            actions.progress(stepNumber, "opening \(name)")
            _ = await DottieScreenTaskRunner.openApplication(named: name)
            try? await Task.sleep(nanoseconds: 800_000_000)
        case .finished, .noneFits:
            break
        }
    }

    /// Apps the request names, plus the user's browser, so "open youtube"
    /// can start from the browser when no site option fits.
    private static func appNamesNamed(in taskText: String) -> [String] {
        var appNames: [String] = []
        for wordGroup in DottieJevDriverPlan.wordGroups(of: taskText) {
            if let installedApp = DottieInstalledApps.shared.installedApp(matchingSpokenName: wordGroup),
               !appNames.contains(installedApp.name) {
                appNames.append(installedApp.name)
            }
        }
        if let exampleWebAddress = URL(string: "https://example.com"),
           let browserURL = NSWorkspace.shared.urlForApplication(toOpen: exampleWebAddress) {
            let browserName = browserURL.deletingPathExtension().lastPathComponent
            if !appNames.contains(browserName) { appNames.append(browserName) }
        }
        return Array(appNames.prefix(6))
    }

    /// Named controls in the front app's focused window (buttons, links,
    /// text boxes, icons with a description), read through Accessibility.
    /// Bounded, so a huge web page can't stall a step.
    static func readControls(onDisplay displayFrame: CGRect) -> [DottieJevDriverPlan.ScreenControl] {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              frontmostApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return [] }
        let applicationElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)
        var focusedWindowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(applicationElement, kAXFocusedWindowAttribute as CFString, &focusedWindowValue) == .success,
              let focusedWindow = DottieAccessibilityCast.element(focusedWindowValue) else { return [] }
        let primaryDisplayHeight = NSScreen.screens.first?.frame.maxY ?? 0
        var controls: [DottieJevDriverPlan.ScreenControl] = []
        var elementsToVisit: [(element: AXUIElement, depth: Int)] = [(focusedWindow, 0)]
        var visitedCount = 0
        let maximumElementsVisited = 800
        let maximumDepth = 25
        // A step never waits long for this: a big web page gives what it
        // has in a quarter second.
        let deadline = Date().addingTimeInterval(0.25)
        // One Accessibility round trip per element, in this order.
        let attributeNames = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, "AXPlaceholderValue",
                              kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute] as CFArray
        while let next = elementsToVisit.popLast(), visitedCount < maximumElementsVisited, controls.count < 200, Date() < deadline {
            visitedCount += 1
            var valuesArray: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(next.element, attributeNames, AXCopyMultipleAttributeOptions(rawValue: 0), &valuesArray) == .success,
                  let values = valuesArray as? [AnyObject], values.count == 8 else { continue }
            let role = values[0] as? String ?? ""
            if DottieJevDriverPlan.controlKind(forRole: role) != nil,
               let positionAXValue = DottieAccessibilityCast.axValue(values[5]),
               let sizeAXValue = DottieAccessibilityCast.axValue(values[6]) {
                var position = CGPoint.zero
                var size = CGSize.zero
                if AXValueGetValue(positionAXValue, .cgPoint, &position), AXValueGetValue(sizeAXValue, .cgSize, &size) {
                    let label = values[1...4].lazy.compactMap { $0 as? String }
                        .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
                    if let control = DottieJevDriverPlan.screenControl(label: label, role: role, accessibilityFrame: CGRect(origin: position, size: size),
                                                                       displayFrame: displayFrame, primaryDisplayHeight: primaryDisplayHeight) {
                        controls.append(control)
                    }
                }
            }
            guard next.depth < maximumDepth, let childElements = values[7] as? [AXUIElement] else { continue }
            elementsToVisit.append(contentsOf: childElements.reversed().map { ($0, next.depth + 1) })
        }
        return controls
    }

    /// Every line of text on the screen, read on the Mac (no model).
    private static func readTexts(on image: CGImage) async -> [DottieJevDriverPlan.ScreenText] {
        await Task.detached(priority: .userInitiated) { () -> [DottieJevDriverPlan.ScreenText] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return []
            }
            return (request.results ?? []).compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return DottieJevDriverPlan.screenText(candidate.string, visionBox: observation.boundingBox)
            }
        }.value
    }

    /// A 32×18 grayscale thumbnail, to tell whether a move changed anything.
    private static func thumbnail(of image: CGImage) -> [UInt8] {
        let width = 32
        let height = 18
        var pixels = [UInt8](repeating: 0, count: width * height)
        let didDraw = pixels.withUnsafeMutableBytes { pixelBuffer -> Bool in
            guard let context = CGContext(
                data: pixelBuffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return didDraw ? pixels : []
    }
}
