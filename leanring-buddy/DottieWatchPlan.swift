//
//  DottieWatchPlan.swift
//  leanring-buddy
//
//  The pure parts of watch me (DottieWatchAndLearn), so they can be tested.
//  The watch me review (27 Nov) found a watch could only learn one short
//  job: it was cut to 3 minutes without saying so, typed narration looked
//  like form typing, private details went to the model, a tour how-to was
//  never found again and nothing watched could be replayed. This holds how
//  long a watch may run and what Dottie says when an ask is cut, which typed
//  text is narration ("NOTE: this is the calendar") and which is private (an
//  SSN, a birth date, a phone number) and stays off the model's page, which
//  frames are kept, how a long tour is cut into parts for at most six text
//  calls, how the model's answer is read, when a how-to fits a job, and how
//  what was watched becomes named app tasks Dottie can do again step by step.
//

import Foundation

/// One thing the user did while Dottie watched.
struct DottieWatchedAction: Equatable {
    enum Kind: String, Equatable {
        /// The app or site changed ("[in Google Chrome: localhost]").
        case place
        case click, rightClick
        /// The pointer rested on something just before a click somewhere
        /// else (a menu that opens while the mouse is over it).
        case hover
        case typed
        /// A key: return, tab, escape, an arrow, or a shortcut ("cmd+s").
        case pressed
        case password
        /// Words the person showing Dottie typed about the screen.
        case narration
    }

    let kind: Kind
    /// What was clicked or pointed at as it read, the keys, or the place.
    var label: String
    /// "button", "link"… when Accessibility named it.
    var role: String?
    /// Where it was, 0-1000 across and down its screen.
    var centerX: Double?
    var centerY: Double?
    /// The typed text or the narration; nil when it was private.
    var text: String?
    /// The text box typed into, when Accessibility named it.
    var fieldLabel: String?
    /// Typed text left out because it looked private.
    var isHiddenBecausePrivate = false
    var pageTitle = ""
    /// The site for a browser, else the app's bundle identifier.
    var placeKey = ""
    var placeName = ""
    /// Seconds since watching started.
    var secondsIntoWatch: Double = 0

    /// The action as one line for the model.
    func line(sendsTypedText: Bool) -> String {
        switch kind {
        case .place: return "[in \(label)]"
        case .click: return "clicked " + describedTarget
        case .rightClick: return "right-clicked " + describedTarget
        case .hover: return "pointed the mouse at " + describedTarget + " without clicking (a menu may have opened)"
        case .typed:
            let fieldText = fieldLabel.map { " into \"\($0)\"" } ?? ""
            if isHiddenBecausePrivate { return "typed private details\(fieldText) (not shown)" }
            guard sendsTypedText, let text else { return "typed text\(fieldText) (not shown)" }
            return "typed \"\(text)\"\(fieldText)"
        case .pressed: return "pressed \(label)"
        case .password: return "typed a password (not saved)"
        case .narration: return "NOTE from the person showing you: \(text ?? "")"
        }
    }

    private var describedTarget: String {
        guard label.isEmpty else { return (role.map { "the \($0) " } ?? "") + "\"\(label)\"" }
        let spotText = centerX.flatMap { across in
            centerY.map { down in " about \(Int(across / 10))% across and \(Int(down / 10))% down the screen" }
        } ?? ""
        return "an unnamed \(role ?? "thing")" + spotText
    }
}

/// A page of an app, as a watched tour explained it.
struct DottieWatchedHowToPage: Codable, Equatable {
    var name: String
    var whatItIs: String
    var howToGetThere: String
    var keyControls: [String]

    var line: String {
        var text = name
        if !whatItIs.isEmpty { text += ": " + whatItIs }
        if !howToGetThere.isEmpty { text += " (get there: \(howToGetThere))" }
        if !keyControls.isEmpty { text += " Controls: " + keyControls.prefix(6).joined(separator: ", ") + "." }
        return text
    }
}

enum DottieWatchPlan {
    static let defaultSeconds = 30
    /// A tour with no time said runs until "done", up to the limit.
    static let defaultTourSeconds = 900
    static let minimumSeconds = 5
    static let maximumSeconds = 900
    /// Frames are kept on disk; past this many, every other one goes.
    static let maximumFramesKept = 300
    static let maximumActions = 1000
    /// Text calls for one watch, however long.
    static let maximumCalls = 6
    static let framesSentForOneJob = 10
    static let framesSentPerTourPart = 3
    static let maximumHowToCharacters = 900
    static let sendsTypedTextDefaultsKey = "dottieWatchSendsTypedText"
    static let fingerprintWidth = 96
    static let fingerprintHeight = 60

    // MARK: How long

    struct WatchLength: Equatable {
        let seconds: Int
        let requestedSeconds: Int?
        let wasCut: Bool
    }

    static func watchLength(requestedSeconds: Int?, isTour: Bool) -> WatchLength {
        let wantedSeconds = requestedSeconds ?? (isTour ? defaultTourSeconds : defaultSeconds)
        let seconds = min(max(wantedSeconds, minimumSeconds), maximumSeconds)
        return WatchLength(seconds: seconds, requestedSeconds: requestedSeconds, wasCut: (requestedSeconds ?? 0) > maximumSeconds)
    }

    /// "30 seconds", "1 minute", "15 minutes", "90 seconds".
    static func spokenDuration(_ seconds: Int) -> String {
        guard seconds >= 60, seconds % 60 == 0 else { return "\(seconds) seconds" }
        let minutes = seconds / 60
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    /// What the voice is told as watching starts. The part after "note for
    /// the user:" is shown to the user as it is (DottieLearningPhrase).
    static func startLine(length: WatchLength, isTour: Bool, onlyFramesReason: String?, looksMedical: Bool) -> String {
        var notes: [String] = []
        if length.wasCut, let requestedSeconds = length.requestedSeconds {
            notes.append("You asked for \(spokenDuration(requestedSeconds)); the longest watch is \(spokenDuration(maximumSeconds)).")
        }
        if let onlyFramesReason {
            notes.append("Only the screen is being watched, not clicks or typing: \(onlyFramesReason).")
        }
        if isTour {
            notes.append("Say \u{201C}done\u{201D} when the tour is over. Lines typed starting with NOTE: are read as explanations.")
        }
        if looksMedical {
            notes.append("Use demo data only: what's on screen goes to an AI model to learn from.")
        }
        var line = "watching for \(spokenDuration(length.seconds))."
        if !notes.isEmpty { line += " note for the user: " + notes.joined(separator: " ") }
        return line + " tell the user to go ahead and do it as they normally would; you'll say what you learned after."
    }

    private static let medicalWords: Set<String> = [
        "openemr", "emr", "ehr", "patient", "patients", "clinic", "medical", "health", "hospital", "chart", "charts", "doctor", "nurse"
    ]

    /// Whether the place or the user's words are about patients, so the
    /// demo data notice shows.
    static func looksMedical(_ texts: [String]) -> Bool {
        let words = Set(texts.joined(separator: " ").lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
        return !words.isDisjoint(with: medicalWords)
    }

    // MARK: What was typed

    /// Typed text that explains the screen rather than fills it in: a line
    /// starting with "NOTE:", or in a tour a long sentence about the screen.
    static func isNarration(_ typedText: String, isTour: Bool) -> Bool {
        let trimmedText = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedText = trimmedText.lowercased()
        if lowercasedText.hasPrefix("note:") || lowercasedText.hasPrefix("note -") { return true }
        guard isTour else { return false }
        let words = trimmedText.split(whereSeparator: \.isWhitespace)
        guard words.count >= 8, let firstWord = words.first?.lowercased() else { return false }
        return ["this", "here", "these", "that", "now", "next", "i'm", "we're"].contains(firstWord)
    }

    /// The narration without its "NOTE:" start.
    static func narrationText(_ typedText: String) -> String {
        var text = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
        for opening in ["note:", "note -"] where text.lowercased().hasPrefix(opening) {
            text = String(text.dropFirst(opening.count))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let privateFieldWords: Set<String> = [
        "ssn", "social", "dob", "birth", "birthday", "birthdate", "phone", "mobile", "cell", "telephone", "tel", "fax",
        "address", "street", "zip", "zipcode", "postal", "postcode", "insurance", "policy", "subscriber", "mrn",
        "medicare", "medicaid", "license", "licence", "passport", "card", "account", "routing", "iban", "pin", "cvv",
        "password", "passcode", "secret"
    ]
    private static let privateFieldPhrases = [
        "medical record", "record number", "member id", "patient id", "group number", "social security", "date of birth", "id number"
    ]

    /// Typed text that stays off the model's page and out of saved tasks:
    /// a field named like an SSN, birth date, phone, address, insurance or
    /// record number, or a value shaped like an SSN or a long number.
    static func looksPrivate(fieldLabel: String?, value: String) -> Bool {
        let fieldText = (fieldLabel ?? "").lowercased()
        let fieldWords = Set(fieldText.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
        if !fieldWords.isDisjoint(with: privateFieldWords) { return true }
        if privateFieldPhrases.contains(where: { fieldText.contains($0) }) { return true }
        if value.range(of: #"\b\d{3}-\d{2}-\d{4}\b"#, options: .regularExpression) != nil { return true }
        return value.filter(\.isNumber).count >= 9
    }

    // MARK: Frames

    /// Positions to keep when `count` items must become `keeping`: evenly
    /// spread, always the first and the last.
    static func evenlySpacedIndices(count: Int, keeping: Int) -> [Int] {
        guard count > 0, keeping > 0 else { return [] }
        guard count > keeping else { return Array(0..<count) }
        guard keeping > 1 else { return [count - 1] }
        return (0..<keeping).map { $0 * (count - 1) / (keeping - 1) }
    }

    /// Whether two 96×60 grey fingerprints show the same screen. A new line
    /// of small text changes few pixels overall but many in one spot, so an
    /// 8×8 block with 6 changed pixels counts as a change too; a blinking
    /// text cursor doesn't.
    static func isSameScreen(_ first: [UInt8], _ second: [UInt8], width: Int = DottieWatchPlan.fingerprintWidth) -> Bool {
        guard first.count == second.count, width > 0, !first.isEmpty else { return false }
        let changedPixels = zip(first, second).map { abs(Int($0) - Int($1)) > 12 }
        if changedPixels.filter({ $0 }).count >= max(1, first.count / 200) { return false }
        let height = first.count / width
        let blockSize = 8
        for blockTop in stride(from: 0, to: height, by: blockSize) {
            for blockLeft in stride(from: 0, to: width, by: blockSize) {
                var changedInBlock = 0
                for row in blockTop..<min(blockTop + blockSize, height) {
                    for column in blockLeft..<min(blockLeft + blockSize, width) where changedPixels[row * width + column] {
                        changedInBlock += 1
                    }
                }
                if changedInBlock >= 6 { return false }
            }
        }
        return true
    }

    /// The frames a part of the watch sends: those taken while it ran (a
    /// little after too, so its last screen shows), evenly spread, or the
    /// nearest one when none fall inside.
    static func frameIndices(frameSeconds: [Double], from startSeconds: Double, to endSeconds: Double, picking: Int) -> [Int] {
        guard !frameSeconds.isEmpty, picking > 0 else { return [] }
        let insideIndices = frameSeconds.indices.filter { frameSeconds[$0] >= startSeconds - 0.5 && frameSeconds[$0] <= endSeconds + 2.5 }
        guard !insideIndices.isEmpty else {
            let nearestIndex = frameSeconds.indices.min { abs(frameSeconds[$0] - endSeconds) < abs(frameSeconds[$1] - endSeconds) }
            return nearestIndex.map { [$0] } ?? []
        }
        return evenlySpacedIndices(count: insideIndices.count, keeping: picking).map { insideIndices[$0] }
    }

    // MARK: Tour parts

    struct WatchPart: Equatable {
        /// Positions in the actions list.
        let actionRange: Range<Int>
        let startSeconds: Double
        let endSeconds: Double
    }

    /// A long watch cut into parts at each new page or note, small parts
    /// joined to the one before, then grouped into at most `maximumCalls`
    /// parts of about the same size, so a tour costs a few text calls.
    static func tourParts(of actions: [DottieWatchedAction], callLimit: Int = DottieWatchPlan.maximumCalls) -> [WatchPart] {
        guard !actions.isEmpty, callLimit > 0 else { return [] }
        var segments: [Range<Int>] = []
        var segmentStart = 0
        var previousPageTitle = actions[0].pageTitle
        for position in actions.indices.dropFirst() {
            let action = actions[position]
            let changesPage = action.kind == .place || (!action.pageTitle.isEmpty && action.pageTitle != previousPageTitle)
            if !action.pageTitle.isEmpty { previousPageTitle = action.pageTitle }
            if action.kind == .narration || changesPage {
                segments.append(segmentStart..<position)
                segmentStart = position
            }
        }
        segments.append(segmentStart..<actions.count)
        var joinedSegments: [Range<Int>] = []
        for segment in segments where !segment.isEmpty {
            if let lastSegment = joinedSegments.last, segment.count < 3 || lastSegment.count < 3 {
                joinedSegments[joinedSegments.count - 1] = lastSegment.lowerBound..<segment.upperBound
            } else {
                joinedSegments.append(segment)
            }
        }
        let targetActionsPerPart = Int((Double(actions.count) / Double(callLimit)).rounded(.up))
        var groupedRanges: [Range<Int>] = []
        var groupStart: Int?
        for segment in joinedSegments {
            let start = groupStart ?? segment.lowerBound
            groupStart = start
            if segment.upperBound - start >= targetActionsPerPart {
                groupedRanges.append(start..<segment.upperBound)
                groupStart = nil
            }
        }
        if let groupStart { groupedRanges.append(groupStart..<actions.count) }
        return groupedRanges.map { range in
            WatchPart(actionRange: range, startSeconds: actions[range.lowerBound].secondsIntoWatch,
                      endSeconds: actions[range.upperBound - 1].secondsIntoWatch)
        }
    }

    // MARK: Asking the model

    static let watcherInstructions = """
    You watch a user work on their Mac (screen frames in order, plus the numbered clicks, typing, hovers and app switches the Mac caught) and write down what they were doing and how, so an assistant can do the same kind of job on its own later, including similar jobs that aren't exactly the same (another sheet, other names).

    Lines that start with "NOTE from the person showing you" are explanations typed for you about the screen, not data being entered: use them to describe pages and controls, never as steps, and leave out clicks in the window where the notes are written. Text marked "(not shown)" was private; never guess it.

    Describe the understanding, not raw clicks: the goal, their method as general steps by meaning, where things are in this app (menus, panels, buttons by their names), and what would change in a similar job. Never write down passwords, patient details or other private values you see.

    Also list the app's pages you saw (what each is for, how to get there, its main controls) and each separate task the user did that could be done again (adding a record, booking something), with the numbers of the action lines that did it, in order, and one example request a person would say for it, using the exact values the user typed.

    Reply with only a JSON object:
    {"name": "2-5 words naming the job or tour", "app": "the app or website", "summary": "one or two plain sentences of what they did", "goal": "what it achieves", "method": ["general step", "..."], "interface_notes": ["where something is", "..."], "works_for": "the kinds of similar tasks this way fits", "pages": [{"name": "page name", "what_it_is": "what it's for", "how_to_get_there": "menu path or link", "key_controls": ["..."]}], "tasks": [{"name": "the task as the app's users say it", "purpose": "one line", "done_when": "what the screen shows when it's done", "example_request": "a request using the typed values", "actions": [3, 4, 5]}]}
    """

    /// One part's message: its numbered lines, the screen's words, the
    /// user's note and which part of the tour it is.
    static func partPrompt(actions: [DottieWatchedAction], part: WatchPart, partNumber: Int, partCount: Int,
                           screenTexts: [String], note: String, sendsTypedText: Bool, droppedActionCount: Int) -> String {
        var actionLines = part.actionRange.map { position in "\(position + 1). " + actions[position].line(sendsTypedText: sendsTypedText) }
        if actionLines.isEmpty { actionLines = ["(no clicks or typing were caught)"] }
        if droppedActionCount > 0, partNumber == partCount {
            actionLines.append("(\(droppedActionCount) more actions after these weren't kept: the watch had more than \(maximumActions))")
        }
        var sections = ["What they did, as caught by the Mac (lines in [brackets] say which app and site):\n" + actionLines.joined(separator: "\n")]
        if !screenTexts.isEmpty {
            sections.append("Words read on the screen during this part (on the Mac):\n" + screenTexts.prefix(60).joined(separator: " | "))
        }
        if !note.isEmpty { sections.append("The user said this is: \(note)") }
        if partCount > 1 {
            sections.append("This is part \(partNumber) of \(partCount) of one long tour; describe only this part. Use the action numbers as given.")
        }
        sections.append("Reply with only the JSON object.")
        return sections.joined(separator: "\n\n")
    }

    struct WatchedTask: Equatable {
        let name: String
        let purpose: String
        let doneWhen: String
        let exampleRequest: String
        /// Action line numbers, counted from 1.
        let actionNumbers: [Int]
    }

    struct Understanding: Equatable {
        var name: String
        var app: String
        var summary: String
        var goal: String
        var method: [String]
        var interfaceNotes: [String]
        var worksFor: String
        var pages: [DottieWatchedHowToPage]
        var tasks: [WatchedTask]
    }

    /// The model's JSON answer, or nil when it named nothing.
    static func understanding(from object: [String: Any]) -> Understanding? {
        let name = text("name", in: object, limit: 60)
        guard !name.isEmpty else { return nil }
        let pages = ((object["pages"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }.compactMap { page -> DottieWatchedHowToPage? in
            let pageName = text("name", in: page, limit: 60)
            guard !pageName.isEmpty else { return nil }
            return DottieWatchedHowToPage(name: pageName, whatItIs: text("what_it_is", in: page, limit: 200),
                                          howToGetThere: text("how_to_get_there", in: page, limit: 160),
                                          keyControls: Array(texts("key_controls", in: page).prefix(8)))
        }
        let tasks = ((object["tasks"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }.compactMap { task -> WatchedTask? in
            let taskName = text("name", in: task, limit: 60)
            let numbers = ((task["actions"] as? [Any]) ?? []).compactMap { ($0 as? Int) ?? ($0 as? String).flatMap { Int($0) } }
            guard !taskName.isEmpty, !numbers.isEmpty else { return nil }
            return WatchedTask(name: taskName, purpose: text("purpose", in: task, limit: 160), doneWhen: text("done_when", in: task, limit: 160),
                               exampleRequest: text("example_request", in: task, limit: 200), actionNumbers: numbers)
        }
        return Understanding(name: name, app: text("app", in: object, limit: 60), summary: text("summary", in: object, limit: 300),
                             goal: text("goal", in: object, limit: 300), method: texts("method", in: object),
                             interfaceNotes: texts("interface_notes", in: object), worksFor: text("works_for", in: object, limit: 300),
                             pages: pages, tasks: tasks)
    }

    private static func text(_ key: String, in dictionary: [String: Any], limit: Int) -> String {
        String(((dictionary[key] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }

    private static func texts(_ key: String, in dictionary: [String: Any]) -> [String] {
        ((dictionary[key] as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { String($0.prefix(200)) }
    }

    /// One understanding from a tour's parts: the first part names it, the
    /// rest add their steps, notes, pages and tasks.
    static func mergedUnderstanding(_ parts: [Understanding]) -> Understanding? {
        guard var merged = parts.first else { return nil }
        for part in parts.dropFirst() {
            if merged.app.isEmpty { merged.app = part.app }
            if !part.summary.isEmpty { merged.summary += " " + part.summary }
            if merged.goal.isEmpty { merged.goal = part.goal }
            merged.method += part.method
            merged.interfaceNotes += part.interfaceNotes
            if merged.worksFor.isEmpty { merged.worksFor = part.worksFor }
            for page in part.pages where !merged.pages.contains(where: { $0.name.caseInsensitiveCompare(page.name) == .orderedSame }) {
                merged.pages.append(page)
            }
            merged.tasks += part.tasks
        }
        merged.summary = String(merged.summary.prefix(600))
        merged.method = Array(merged.method.prefix(16))
        merged.interfaceNotes = Array(merged.interfaceNotes.prefix(20))
        merged.pages = Array(merged.pages.prefix(30))
        return merged
    }

    // MARK: Finding a how-to again

    /// Whether a watched how-to fits a job. The old rule (a shared topic
    /// word and the same app) missed every website, whose front app is the
    /// browser, so the how-to's own places count too: a tour fits any job
    /// in its place, a job how-to one in its place that shares a word.
    static func howToFits(_ howTo: DottieWatchedHowTo, taskText: String, frontmostAppName: String?, frontPlaceKey: String?) -> Bool {
        let topicText = ([howTo.goal] + (howTo.exampleRequests ?? [])).joined(separator: " ")
        if DottieTaskMatching.howToFits(taskText: taskText, frontmostAppName: frontmostAppName, howToName: howTo.name,
                                        howToGoal: topicText, howToAppName: howTo.appName) {
            return true
        }
        let howToPlaces = Set(howTo.places ?? [])
        guard !howToPlaces.isEmpty else { return false }
        let jobPlaces = DottieAppTaskPlan.placeKeys(frontPlaceKey: frontPlaceKey, requestText: taskText)
        guard !jobPlaces.isDisjoint(with: howToPlaces) else { return false }
        if howTo.isTour { return true }
        let pageWords = (howTo.pages ?? []).map(\.name).joined(separator: " ")
        let howToWords = DottieTaskMatching.contentWords(howTo.name + " " + topicText + " " + pageWords)
            .subtracting(DottieTaskMatching.contentWords(howTo.appName))
        return !DottieTaskMatching.contentWords(taskText).isDisjoint(with: howToWords)
    }

    /// The how-to as a job's notes, at most `maximumHowToCharacters`. A
    /// tour sends only its pages that the job or the page in front names
    /// (or just their names when none do).
    static func promptText(for howTo: DottieWatchedHowTo, taskText: String, frontPageTitle: String?) -> String {
        var text = howTo.promptText
        let pages = howTo.pages ?? []
        if !pages.isEmpty {
            let jobWords = DottieTaskMatching.contentWords(taskText + " " + (frontPageTitle ?? ""))
            let matchingPages = pages.filter { page in
                !jobWords.isDisjoint(with: DottieTaskMatching.contentWords(page.name + " " + page.whatItIs + " " + page.howToGetThere))
            }
            if matchingPages.isEmpty {
                text += "\nPages it showed: " + pages.prefix(12).map(\.name).joined(separator: ", ")
            } else {
                text += "\nPages that matter here: " + matchingPages.prefix(4).map(\.line).joined(separator: " | ")
            }
        }
        guard text.count > maximumHowToCharacters else { return text }
        return String(text.prefix(maximumHowToCharacters - 1)) + "…"
    }

    // MARK: Tasks from what was watched

    /// The tasks the model found, as app tasks Dottie can do again: their
    /// actions as steps, typed values from the example request marked so a
    /// new request's words go there, private values left for Jev.
    static func appTasks(from understanding: Understanding, actions: [DottieWatchedAction], now: Date) -> [DottieAppTask] {
        understanding.tasks.compactMap { watchedTask -> DottieAppTask? in
            let positions = Array(Set(watchedTask.actionNumbers.map { $0 - 1 }.filter { actions.indices.contains($0) })).sorted()
            // Only the actions in the task's own place: a click into the
            // notes window the tour typed in isn't a step of the task.
            let placeKeys = positions.map { actions[$0].placeKey }.filter { !$0.isEmpty }
            guard let mainPlaceKey = Dictionary(grouping: placeKeys, by: { $0 })
                .max(by: { ($0.value.count, $1.key) < ($1.value.count, $0.key) })?.key else { return nil }
            let chosenActions = positions.map { actions[$0] }.filter { $0.placeKey == mainPlaceKey }
            let exampleRequest = watchedTask.exampleRequest.isEmpty ? watchedTask.name : watchedTask.exampleRequest
            let steps = Self.steps(from: chosenActions, exampleRequest: exampleRequest)
            guard !steps.isEmpty, steps.count <= DottieAppTaskPlan.maximumStepsPerTask else { return nil }
            let firstPlaceName = chosenActions.map(\.placeName).first { !$0.isEmpty }
            return DottieAppTask(
                id: UUID(), name: watchedTask.name, purpose: watchedTask.purpose, doneWhen: watchedTask.doneWhen, tips: [],
                appName: understanding.app.isEmpty ? (firstPlaceName ?? "this app") : understanding.app, places: [mainPlaceKey],
                exampleRequests: [exampleRequest], steps: steps, stepsRecordedFor: exampleRequest,
                finalPageTitle: chosenActions.last?.pageTitle, timesRun: 0, timesSucceeded: 0, problems: [],
                createdAt: now, lastUsed: now, isNamed: true, learnedByWatching: true
            )
        }
    }

    /// Watched actions as task steps. Notes, places and passwords aren't
    /// steps; Return after typing joins the typing step.
    static func steps(from chosenActions: [DottieWatchedAction], exampleRequest: String) -> [DottieAppTaskStep] {
        var steps: [DottieAppTaskStep] = []
        for action in chosenActions {
            switch action.kind {
            case .click, .rightClick, .hover:
                guard !action.label.isEmpty else {
                    steps.append(step(.jevPicks, label: action.line(sendsTypedText: false), from: action))
                    continue
                }
                let kind: DottieAppTaskStep.Kind = action.kind == .click ? .click : (action.kind == .rightClick ? .rightClick : .hover)
                steps.append(step(kind, label: action.label, role: action.role, from: action))
            case .typed:
                let typedText = action.isHiddenBecausePrivate ? nil : action.text
                let cameFromRequest = typedText.map { DottieAppTaskPlan.textCameFromRequest($0, requestText: exampleRequest) } ?? false
                if let fieldLabel = action.fieldLabel, !fieldLabel.isEmpty {
                    steps.append(step(.typeIntoField, label: fieldLabel, role: "text box", text: typedText, cameFromRequest: cameFromRequest, from: action))
                } else {
                    steps.append(step(.typeText, label: "", text: typedText, cameFromRequest: cameFromRequest, from: action))
                }
            case .pressed:
                if action.label == "return", let lastStep = steps.last,
                   lastStep.kind == .typeIntoField || lastStep.kind == .typeText, !lastStep.pressesReturn {
                    steps[steps.count - 1] = withReturn(lastStep)
                } else if action.label == "return" {
                    steps.append(step(.pressReturn, label: "", from: action))
                } else {
                    steps.append(step(.pressKeys, label: action.label, from: action))
                }
            case .place, .password, .narration:
                continue
            }
        }
        return steps
    }

    private static func step(_ kind: DottieAppTaskStep.Kind, label: String, role: String? = nil, text: String? = nil,
                             cameFromRequest: Bool = false, from action: DottieWatchedAction) -> DottieAppTaskStep {
        DottieAppTaskStep(kind: kind, label: label, role: role, centerX: action.centerX, centerY: action.centerY, text: text,
                          textCameFromRequest: cameFromRequest, pressesReturn: false, pageTitle: action.pageTitle)
    }

    private static func withReturn(_ step: DottieAppTaskStep) -> DottieAppTaskStep {
        DottieAppTaskStep(kind: step.kind, label: step.label, role: step.role, centerX: step.centerX, centerY: step.centerY, text: step.text,
                          textCameFromRequest: step.textCameFromRequest, pressesReturn: true, pageTitle: step.pageTitle)
    }

    /// The task list with newly watched tasks: one of the same name in the
    /// same place gets the new example and, while it has never worked from
    /// a job yet, the new steps; anything else is added.
    static func tasksAfterWatching(_ existingTasks: [DottieAppTask], adding watchedTasks: [DottieAppTask]) -> [DottieAppTask] {
        var tasks = existingTasks
        for watchedTask in watchedTasks {
            guard let sameIndex = tasks.firstIndex(where: {
                $0.isNamed && $0.name.caseInsensitiveCompare(watchedTask.name) == .orderedSame && !Set($0.places).isDisjoint(with: watchedTask.places)
            }) else {
                tasks.append(watchedTask)
                continue
            }
            var task = tasks[sameIndex]
            for request in watchedTask.exampleRequests { task.exampleRequests = DottieAppTaskPlan.keptExamples(task.exampleRequests, adding: request) }
            task.places = Array(Set(task.places).union(watchedTask.places)).sorted()
            if task.timesSucceeded == 0 {
                task.steps = watchedTask.steps
                task.stepsRecordedFor = watchedTask.stepsRecordedFor
                task.finalPageTitle = watchedTask.finalPageTitle
                task.learnedByWatching = true
            }
            if task.purpose.isEmpty { task.purpose = watchedTask.purpose }
            if task.doneWhen.isEmpty { task.doneWhen = watchedTask.doneWhen }
            task.lastUsed = max(task.lastUsed, watchedTask.lastUsed)
            tasks[sameIndex] = task
        }
        return DottieAppTaskPlan.trimmed(tasks)
    }
}

// MARK: - Hovers

/// Spots when the pointer rests on something just before a click somewhere
/// else: the way a menu that opens on hover is used. The recorder feeds it
/// the pointer every 0.3 s while watching.
struct DottieWatchHoverTracker: Equatable {
    struct Rest: Equatable {
        let pointX: Double
        let pointY: Double
        let startedAt: Double
    }

    /// How still and how long counts as resting on something.
    static let stillDistance = 4.0
    static let restSeconds = 0.45
    /// A click this far from the rest, this soon after, makes it a hover.
    static let clickDistance = 30.0
    static let clickWithinSeconds = 5.0

    private var candidateX = 0.0
    private var candidateY = 0.0
    private var candidateSince: Double?
    private var reportedCurrentRest = false
    /// The last rest, waiting for a click.
    private(set) var lastRest: Rest?

    /// A new pointer spot. Returns the rest when one has just begun, so
    /// the recorder can read what's under the pointer once.
    mutating func notePointer(pointX: Double, pointY: Double, at seconds: Double) -> Rest? {
        guard let since = candidateSince, hypot(pointX - candidateX, pointY - candidateY) <= Self.stillDistance else {
            candidateX = pointX
            candidateY = pointY
            candidateSince = seconds
            reportedCurrentRest = false
            return nil
        }
        guard !reportedCurrentRest, seconds - since >= Self.restSeconds else { return nil }
        reportedCurrentRest = true
        let rest = Rest(pointX: candidateX, pointY: candidateY, startedAt: since)
        lastRest = rest
        return rest
    }

    /// A click: the rest before it when it counts as a hover. A click ends
    /// the wait either way.
    mutating func restBeforeClick(pointX: Double, pointY: Double, at seconds: Double) -> Rest? {
        defer { lastRest = nil }
        guard let lastRest, seconds - lastRest.startedAt <= Self.clickWithinSeconds,
              hypot(pointX - lastRest.pointX, pointY - lastRest.pointY) >= Self.clickDistance else { return nil }
        return lastRest
    }
}
