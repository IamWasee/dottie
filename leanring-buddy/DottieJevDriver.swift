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
        case drag(fromLabel: String, fromX: Double, fromY: Double, toLabel: String, toX: Double, toY: Double)
        case typeText(String, pressesReturn: Bool)
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
            case .drag(let fromLabel, _, _, let toLabel, _, _): return "Drag \"\(fromLabel)\" onto \"\(toLabel)\""
            case .pressKeys(let keys, let meaning): return "Press \(keys) (\(meaning))"
            case .scrollLeft: return "Scroll or swipe left"
            case .scrollRight: return "Scroll or swipe right"
            case .quickMacAction(let text): return "Do it straight on the Mac without the screen: \"\(text)\""
            case .recallAppMemory: return "Look up what Dottie remembers about this app first (its buttons, where they are, and how the user did this before)"
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
            case .finished: return "Nothing left to do: the goal is already done on this screen"
            case .noneFits: return "None of these moves helps with the goal"
            }
        }

        /// Moves that load a page or an app, which take longer to draw.
        var opensSomethingNew: Bool {
            switch self {
            case .openSite, .searchWeb, .openApp, .goBack, .pressReturn, .doubleClick, .pressKeys, .quickMacAction: return true
            case .typeText(_, let pressesReturn): return pressesReturn
            case .click, .clickControl, .clickUnlabeled, .rightClick, .drag, .scrollDown, .scrollUp, .scrollLeft, .scrollRight, .recallAppMemory, .finished, .noneFits: return false
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
            case .drag(let fromLabel, _, _, let toLabel, _, _): return "drag:\(fromLabel.lowercased())>\(toLabel.lowercased())"
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
            case .drag(let fromLabel, _, _, let toLabel, _, _): return "dragged \(fromLabel) onto \(toLabel)"
            case .pressKeys(let keys, _): return "pressed \(keys)"
            case .scrollLeft: return "scrolled left"
            case .scrollRight: return "scrolled right"
            case .quickMacAction(let text): return "did \"\(text)\" on the Mac"
            case .recallAppMemory: return "looked up what Dottie remembers about this app"
            case .typeText(let text, let pressesReturn): return pressesReturn ? "typed \"\(text)\" and pressed Return" : "typed \"\(text)\""
            case .pressReturn: return "pressed Return"
            case .scrollDown: return "scrolled down"
            case .scrollUp: return "scrolled up"
            case .goBack: return "went back"
            case .openSite(let address): return "opened \(address)"
            case .searchWeb(let text): return "searched the web for \(text)"
            case .openApp(let name): return "opened \(name)"
            case .finished: return "finished"
            case .noneFits: return "stopped"
            }
        }
    }

    struct Option: Equatable {
        let key: String
        let move: Move
    }

    struct Answer: Equatable {
        let move: Move
        let probability: Double
        let confidence: Double
        let doneProbability: Double?
    }

    enum Decision: Equatable {
        case act(Move)
        case finished
        case unsure
    }

    static let choiceQuestionName = "next_move"
    static let doneQuestionName = "done"
    /// Jev takes up to 255 options; this many screen texts leaves room.
    static let maximumScreenTextOptions = 120
    /// Every option together stays under Jev's 255; screen texts give way first.
    static let maximumOptions = 250
    static let maximumControlOptions = 50
    static let maximumDoubleAndRightClickTargets = 8
    /// Jev saying the goal is done this surely ends the job.
    static let doneProbabilityToFinish = 0.8
    /// Below both of these Jev is guessing among many; the step model goes on.
    static let minimumConfidence = 0.15
    static let minimumTopProbability = 0.2
    /// The Jev lane's own step budget before the step model takes over.
    static let maximumSteps = 25
    /// This many moves in a row that change nothing hand over.
    static let maximumMovesWithoutChange = 3

    // MARK: Pieces of the request

    /// Words the job may need typed, taken from the user's own request:
    /// quoted text, and what follows "search for", "type", "called" and the
    /// like, up to "on", "in", "and" or the end.
    static func textPieces(from taskText: String) -> [String] {
        var pieces: [String] = []
        let quotePattern = "[\"“”]([^\"“”]{1,120})[\"“”]"
        for match in matches(of: quotePattern, in: taskText) {
            pieces.append(match)
        }
        let leadPattern = "(?i)\\b(?:search(?:ing|ed|es)?(?: for| up)?|look(?:ing)? up|typ(?:e|ing)|writ(?:e|ing)|enter(?:ing)?|called|named|titled|say(?:ing)?)\\s+(?!(?:button|bar|box|field|icon|results?|tab|page|engine|history|filters?|settings)\\b)(.+?)(?=\\s+(?:on|in|into|and then|and|then|to|at|from|using)\\s|[,.!?]|$)"
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
        offersAppMemory: Bool = false
    ) -> [Option] {
        var leadingMoves: [Move] = offersAppMemory ? [.recallAppMemory] : []
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
        trailingMoves.append(contentsOf: [.pressReturn, .scrollDown, .scrollUp, .scrollLeft, .scrollRight, .goBack])
        trailingMoves.append(contentsOf: everydayKeys.map { Move.pressKeys(keys: $0.keys, meaning: $0.meaning) })
        trailingMoves.append(contentsOf: [.finished, .noneFits])

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

    /// Keys people press all day, each with what it does, so Jev can pick a
    /// shortcut the way a person would instead of hunting for a button.
    static let everydayKeys: [(keys: String, meaning: String)] = [
        ("cmd+l", "go to the browser's address bar"),
        ("cmd+f", "find on this page"),
        ("cmd+t", "open a new tab"),
        ("cmd+w", "close this tab or window"),
        ("cmd+n", "new window or new document"),
        ("cmd+s", "save"),
        ("cmd+a", "select everything"),
        ("cmd+c", "copy"),
        ("cmd+v", "paste"),
        ("cmd+z", "undo"),
        ("cmd+m", "minimize this window"),
        ("cmd+q", "quit this app"),
        ("escape", "close a menu, popup or dialog"),
        ("tab", "go to the next field"),
        ("space", "play or pause, or tick the selected box"),
        ("down", "move down one item"),
        ("up", "move up one item"),
        ("cmd+]", "go forward a page")
    ]

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
    static func requestBody(goal: String, movesSoFar: [String], knownHowTo: String, options: [Option]) -> [String: Any] {
        var state = "The user asked Dottie, their Mac assistant, to do this on their Mac: \(goal)\n\(DottieJevProtocol.screenshotReferenceLine) (their screen right now)."
        if movesSoFar.isEmpty {
            state += "\nNothing has been done yet."
        } else {
            state += "\nDone so far, in order: " + movesSoFar.suffix(12).joined(separator: "; ") + "."
        }
        let trimmedHowTo = knownHowTo.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedHowTo.isEmpty {
            state += "\nWhat Dottie knows about this kind of job: " + String(trimmedHowTo.prefix(4500))
        }
        var criteria: [String: String] = [:]
        for option in options {
            criteria[option.key] = option.move.description
        }
        return [
            "state": state,
            "questions": [
                choiceQuestionName: [
                    "type": "choice",
                    "instructions": "Pick the one next move that gets the user's request done, the way a person sitting at this Mac would do it next. If the app or site isn't open yet, open it first. Click a text box before typing into it. A keyboard shortcut or a named button is often quickest; pick the icon option only when the thing to click has no words or name.",
                    "criteria": criteria
                ],
                doneQuestionName: [
                    "type": "noul",
                    "instructions": "Is the user's request fully done on this screen already?"
                ]
            ]
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
        return Answer(move: chosenOption.move, probability: probability, confidence: confidence, doneProbability: doneProbability)
    }

    static func decision(for answer: Answer) -> Decision {
        if let doneProbability = answer.doneProbability, doneProbability >= doneProbabilityToFinish { return .finished }
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
        case .drag, .rightClick, .quickMacAction: return true
        case .pressKeys(let keys, _): return ["cmd+q", "cmd+w"].contains(keys)
        default: return false
        }
    }

    /// The step model's note when it takes over.
    static func handOverNote(movesSoFar: [String], reason: String) -> String {
        guard !movesSoFar.isEmpty else { return "" }
        return "Dottie already did these steps on screen: \(movesSoFar.joined(separator: "; ")). \(reason) Carry on from the screen as it is now; don't redo them."
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
        let openSite: @MainActor (_ address: String, _ stepNumber: Int) async -> Void
    }

    private static let finishedCountKey = "DottieJevDriverFinishedCount"
    private static let handedOverCountKey = "DottieJevDriverHandedOverCount"

    /// How often Jev finished a job alone, for the log and Settings.
    static var aloneReport: String {
        let finishedCount = UserDefaults.standard.integer(forKey: finishedCountKey)
        let handedOverCount = UserDefaults.standard.integer(forKey: handedOverCountKey)
        return "Jev finished \(finishedCount) of \(finishedCount + handedOverCount) screen jobs alone"
    }

    static func run(taskText: String, knownHowTo givenHowTo: String, actions: Actions) async -> Outcome {
        var knownHowTo = givenHowTo
        // App memory is read only when Jev asks, once per job.
        var hasRecalledAppMemory = false
        let textPieces = DottieJevDriverPlan.textPieces(from: taskText)
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
        var labelsClickedFromMemory = Set<String>()

        func handOver(_ reason: String) -> Outcome {
            UserDefaults.standard.set(UserDefaults.standard.integer(forKey: handedOverCountKey) + 1, forKey: handedOverCountKey)
            DottieLog.notice("🎯 Jev handed the screen job over after \(movesSoFar.count) moves (\(reason)); \(aloneReport)")
            return .handedOver(note: DottieJevDriverPlan.handOverNote(movesSoFar: movesSoFar, reason: reason))
        }

        for stepNumber in 1...DottieJevDriverPlan.maximumSteps {
            if Task.isCancelled { return .handedOver(note: "") }
            guard let screen = await DottieDisplayCapture.captureActiveDisplay(maximumDimension: DottieJevProtocol.maximumImageSide) else {
                return movesSoFar.isEmpty ? .notTried : handOver("The screen couldn't be read.")
            }
            let screenThumbnail = thumbnail(of: screen.image)
            // Exploring: a move that left the screen as it was is struck
            // off for that screen, so Jev's next best pick gets its turn.
            if let previousScreenThumbnail, let lastMoveSignature,
               DottieJevDriverPlan.isSameScreen(previousScreenThumbnail, screenThumbnail) {
                triedSignaturesByScreen[previousScreenThumbnail, default: []].insert(lastMoveSignature)
                movesWithoutChange += 1
                if movesWithoutChange >= DottieJevDriverPlan.maximumMovesWithoutChange {
                    return handOver("The last moves didn't change the screen.")
                }
            } else {
                movesWithoutChange = 0
            }
            let screenKey = triedSignaturesByScreen.keys.first { DottieJevDriverPlan.isSameScreen($0, screenThumbnail) } ?? screenThumbnail

            let allScreenTexts = await readTexts(on: screen.image)
            let appMemory = DottieAppMemory.shared
            let frontPageIdentity = appMemory.frontPageIdentity()
            if let clickWaitingForResult, let frontPageIdentity,
               frontPageIdentity.key != clickWaitingForResult.pageKey {
                appMemory.noteClick(bundleIdentifier: clickWaitingForResult.bundleIdentifier, fromPageKey: clickWaitingForResult.pageKey,
                                    centerX: clickWaitingForResult.centerX, centerY: clickWaitingForResult.centerY,
                                    label: clickWaitingForResult.label, toPageKey: frontPageIdentity.key, toPageTitle: frontPageIdentity.title)
            }
            clickWaitingForResult = nil
            let screenControls = readControls(onDisplay: screen.displayFrame)
            appMemory.notePageFromScreenJob(elements: allScreenTexts.map {
                DottieAppPage.Element(label: $0.text, centerX: $0.centerX, centerY: $0.centerY)
            }, controls: screenControls.map {
                DottieAppPage.Control(label: $0.label, kind: $0.kind, centerX: $0.centerX, centerY: $0.centerY)
            })
            let screenTexts = DottieJevDriverPlan.clickableTexts(from: allScreenTexts, taskText: taskText)

            // Something clicked here before led where this task is going:
            // click it now (where it sits on this screen) without asking Jev.
            if let knownPage = appMemory.knownFrontPage(),
               let rememberedClick = DottieAppMemoryPlan.rememberedClick(
                   on: knownPage, forTask: taskText,
                   visibleLabels: allScreenTexts.map(\.text), alreadyClickedLabels: labelsClickedFromMemory
               ),
               let visibleText = allScreenTexts.first(where: {
                   DottieAppMemoryPlan.comparableWords($0.text) == DottieAppMemoryPlan.comparableWords(rememberedClick.label)
               }) {
                let move = DottieJevDriverPlan.Move.click(label: visibleText.text, centerX: visibleText.centerX, centerY: visibleText.centerY)
                labelsClickedFromMemory.insert(DottieAppMemoryPlan.comparableWords(rememberedClick.label))
                DottieLog.notice("🎯 App memory clicked a remembered button without asking Jev")
                await perform(move, screen: screen, stepNumber: stepNumber, taskText: taskText, movesSoFar: movesSoFar, actions: actions)
                movesSoFar.append(move.summary)
                previousScreenThumbnail = screenKey
                lastMoveSignature = move.signature
                if let frontPageIdentity {
                    clickWaitingForResult = (frontPageIdentity.bundleIdentifier, frontPageIdentity.key, visibleText.text, visibleText.centerX, visibleText.centerY)
                }
                await waitForScreenToSettle(maximumSeconds: move.opensSomethingNew ? 5 : 2)
                continue
            }
            let options = DottieJevDriverPlan.options(
                screenTexts: screenTexts,
                textPieces: textPieces,
                siteAddresses: siteAddresses,
                appNames: appNames,
                alreadyTriedSignatures: triedSignaturesByScreen[screenKey] ?? [],
                frontSiteHost: DottieReplayContext.current().siteHost,
                screenControls: screenControls,
                taskText: taskText,
                offersAppMemory: !hasRecalledAppMemory && appMemory.hasMemoryOfFrontApp()
            )
            let requestBody = DottieJevDriverPlan.requestBody(goal: taskText, movesSoFar: movesSoFar, knownHowTo: knownHowTo, options: options)
            guard let answerData = await DottieJev.answer(to: requestBody, screenImage: screen.image),
                  let answer = DottieJevDriverPlan.answer(fromAnswer: answerData, options: options) else {
                return movesSoFar.isEmpty ? .notTried : handOver("Jev didn't answer.")
            }
            if Task.isCancelled { return .handedOver(note: "") }

            switch DottieJevDriverPlan.decision(for: answer) {
            case .finished:
                if DottieJevDriverPlan.asksForInformation(taskText) {
                    return handOver("The screen should now show what the user asked about: read it and finish with the answer.")
                }
                UserDefaults.standard.set(UserDefaults.standard.integer(forKey: finishedCountKey) + 1, forKey: finishedCountKey)
                DottieLog.notice("🎯 Jev finished the screen job alone in \(movesSoFar.count) moves; \(aloneReport)")
                return .finished(stepCount: movesSoFar.count)
            case .unsure:
                return movesSoFar.isEmpty ? .notTried : handOver("Jev wasn't sure what comes next.")
            case .act(.recallAppMemory):
                hasRecalledAppMemory = true
                actions.progress(stepNumber, "remembering how this app works")
                let rememberedText = await appMemory.recall(forTask: taskText, readsPageClosely: true)
                if !rememberedText.isEmpty { knownHowTo += "\n" + rememberedText }
                movesSoFar.append(DottieJevDriverPlan.Move.recallAppMemory.summary)
                // Nothing on screen changed on purpose: not a move to strike off.
                previousScreenThumbnail = nil
                lastMoveSignature = nil
            case .act(let move):
                if case .typeText = move, DottieScreenActionPerformer.isFocusedFieldSecure {
                    return handOver("A password box is selected.")
                }
                await perform(move, screen: screen, stepNumber: stepNumber, taskText: taskText, movesSoFar: movesSoFar, actions: actions)
                movesSoFar.append(move.summary)
                previousScreenThumbnail = screenKey
                lastMoveSignature = move.signature
                if case .click(let label, let centerX, let centerY) = move, let frontPageIdentity {
                    clickWaitingForResult = (frontPageIdentity.bundleIdentifier, frontPageIdentity.key, label, centerX, centerY)
                }
                // Let the app draw what the move opened before looking again:
                // a page still loading looked like "nothing changed" and the
                // move was struck off.
                await waitForScreenToSettle(maximumSeconds: move.opensSomethingNew ? 5 : 2)
            }
        }
        return handOver("Jev used its step budget.")
    }

    /// Waits until two looks a moment apart show the same screen (the page
    /// or app has finished drawing), or the time is up.
    private static func waitForScreenToSettle(maximumSeconds: Double) async {
        let startedAt = Date()
        try? await Task.sleep(nanoseconds: 400_000_000)
        var lastThumbnail: [UInt8]?
        while Date().timeIntervalSince(startedAt) < maximumSeconds, !Task.isCancelled {
            guard let look = await DottieDisplayCapture.captureActiveDisplay(maximumDimension: 320) else { return }
            let lookThumbnail = thumbnail(of: look.image)
            if let lastThumbnail, DottieJevDriverPlan.isSameScreen(lastThumbnail, lookThumbnail) { return }
            lastThumbnail = lookThumbnail
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    private static func perform(_ move: DottieJevDriverPlan.Move, screen: DottieDisplayCapture.Screenshot, stepNumber: Int, taskText: String, movesSoFar: [String], actions: Actions) async {
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
        case .recallAppMemory:
            break
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
            await actions.openSite(address, stepNumber)
        case .searchWeb(let text):
            var searchComponents = URLComponents(string: "https://www.google.com/search")
            searchComponents?.queryItems = [URLQueryItem(name: "q", value: text)]
            await actions.openSite(searchComponents?.url?.absoluteString ?? "google.com", stepNumber)
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
