//
//  DottieHelperFollowThrough.swift
//  leanring-buddy
//
//  Two checks that keep voice Dottie honest about her helpers (Dots).
//  The hand-off check: when an answer says a helper is on it, or the user
//  asked for a helper, but start_helper was never called, the app tells
//  Live so and asks it to hand the work over now. The recent work note:
//  which helper did what lately, and the files it touched, sent with each
//  turn, so "open that file" or "change it again" goes back to the helper
//  that did the work instead of the second brain. Foundation only, so the
//  rules can be unit tested.
//

import Foundation

enum DottieHelperHandOffCheck {
    /// Tools that really give work to a helper.
    static let handOffFunctionNames: Set<String> = ["start_helper", "start_team", "keep_working"]
    /// Tools that only ask about helpers. A question that used one of
    /// these was about a helper, not a new job for one.
    static let helperStatusFunctionNames: Set<String> = ["list_helpers", "check_helper", "stop_helper", "open_helper_result"]

    /// Words that, said about a helper, mean the work is with it now.
    private static let handOffPhrases = [
        "i'll have", "i will have", "i'll get", "i will get", "i'll ask", "i will ask",
        "i've asked", "i have asked", "i asked", "i'm asking", "asking",
        "i've handed", "i handed", "handing", "handed", "passing", "passed",
        "i've sent", "i sent", "sending", "sent it", "sent that", "sent this",
        "i've given", "i gave", "giving", "gave it",
        "i've started", "i started", "starting", "started", "kicked off", "spun up", "set up",
        "is on it", "is on that", "on it now", "is working on", "will work on", "is going to", "will handle",
        "is handling", "will take care", "is taking care", "will do it", "will get it", "will get that",
        "will look into", "is looking into", "will build", "is building", "will write", "is writing",
        "put it on", "put that on"
    ]

    /// Words that turn a hand-off sentence into the opposite.
    private static let negationPattern = "\\b(can't|cannot|couldn't|don't|didn't|won't|wasn't|isn't|not|no helper|no dot)\\b"

    /// True when Dottie's spoken answer tells the user a helper has the
    /// work. The sentence has to name a helper ("a helper", "the dots",
    /// or a helper's own name) and say it's taking the job.
    static func answerClaimsHandOff(_ modelTranscript: String, helperNames: [String]) -> Bool {
        for sentence in sentences(in: modelTranscript) {
            guard mentionsAHelper(sentence, helperNames: helperNames) else { continue }
            if sentence.range(of: negationPattern, options: .regularExpression) != nil { continue }
            if handOffPhrases.contains(where: { sentence.contains($0) }) { return true }
        }
        return false
    }

    /// True when the user asked for a helper to do something: "have a
    /// helper make…", "ask Jarvis to…", "send this to the dots".
    static func userAskedForHelper(_ userText: String, helperNames: [String]) -> Bool {
        let text = normalized(userText)
        guard !text.isEmpty else { return false }
        let helperWords = ["a helper", "the helper", "my helper", "helpers", "a dot", "the dot", "my dot", "dots"]
        let askVerbs = ["have", "get", "ask", "tell", "use", "send", "give", "let", "put", "hand"]
        var helperReferences = helperWords
        helperReferences += usableHelperNames(helperNames)
        // "can one of my helpers make…" asks too, but "what can my helpers
        // do?" is a question about them, not a job.
        let isQuestionAboutHelpers = text.range(of: "^\\s*(what|how|which|who|why|when|where)\\b", options: .regularExpression) != nil
        let questionVerbs = isQuestionAboutHelpers ? [] : ["can", "could", "would", "will"]
        for helperReference in helperReferences {
            let escapedReference = NSRegularExpression.escapedPattern(for: helperReference)
            for askVerb in askVerbs + questionVerbs {
                let pattern = "\\b\(askVerb)\\b[^.?!]{0,16}\\b\(escapedReference)\\b"
                if text.range(of: pattern, options: .regularExpression) != nil { return true }
            }
        }
        // Talking to a helper by name: "Jarvis, look up flights to Bangkok".
        for helperName in usableHelperNames(helperNames) {
            let pattern = "^\\s*(hey\\s+)?\(NSRegularExpression.escapedPattern(for: helperName))\\s*[,:]\\s*\\S"
            if text.range(of: pattern, options: .regularExpression) != nil { return true }
        }
        return false
    }

    /// Whether this finished question needs the app to step in.
    /// `busyHelperNames` are helpers working right now: "Jarvis is on it"
    /// about a busy Jarvis is a status, not a missed hand-off.
    static func needsHandOffNudge(
        userText: String,
        modelTranscript: String,
        calledFunctionNames: Set<String>,
        helperNames: [String],
        busyHelperNames: [String]
    ) -> Bool {
        if !calledFunctionNames.isDisjoint(with: handOffFunctionNames) { return false }
        if !calledFunctionNames.isDisjoint(with: helperStatusFunctionNames) { return false }
        let idleHelperNames = helperNames.filter { helperName in
            !busyHelperNames.contains { $0.caseInsensitiveCompare(helperName) == .orderedSame }
        }
        let claimsHandOff = answerClaimsHandOff(modelTranscript, helperNames: idleHelperNames)
            && !mentionsOnlyBusyHelpers(modelTranscript, busyHelperNames: busyHelperNames, idleHelperNames: idleHelperNames)
        if claimsHandOff { return true }
        guard userAskedForHelper(userText, helperNames: helperNames) else { return false }
        // Asking back ("which helper?", "what should it make?") is fine.
        let lastSentence = modelTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if lastSentence.hasSuffix("?") { return false }
        // Another way of doing the work (on the screen, by script) was picked.
        let otherWorkFunctionNames: Set<String> = ["do_task_on_screen", "run_applescript", "run_shortcut", "ask_brain"]
        return calledFunctionNames.isDisjoint(with: otherWorkFunctionNames)
    }

    /// What Live is told when a hand-off was promised or asked for but
    /// never made.
    static func nudgeText(answerClaimedHandOff: Bool) -> String {
        let whatWentWrong = answerClaimedHandOff
            ? "you told the user a helper is doing this, but start_helper was never called, so no helper is working on it."
            : "the user asked for a helper, but start_helper was never called, so no helper is working on it."
        return "[check from the app] \(whatWentWrong) call start_helper now with a task that stands on its own (helper_name if they named one; never the second brain), then say only a few words, like \"okay, it's with Jarvis now\". if you meant not to hand it off, say that in one short sentence instead."
    }

    // MARK: - Words

    static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
    }

    private static func sentences(in text: String) -> [String] {
        normalized(text)
            .components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func mentionsAHelper(_ sentence: String, helperNames: [String]) -> Bool {
        if sentence.range(of: "\\b(helper|helpers|dots)\\b", options: .regularExpression) != nil { return true }
        // "dot" alone, but not a web address read out ("dot com").
        if sentence.range(of: "\\b(a|the|your|my) dot\\b(?! com| org| net| io| app)", options: .regularExpression) != nil { return true }
        return usableHelperNames(helperNames).contains { helperName in
            sentence.range(of: "\\b\(NSRegularExpression.escapedPattern(for: helperName))\\b", options: .regularExpression) != nil
        }
    }

    private static func mentionsOnlyBusyHelpers(_ modelTranscript: String, busyHelperNames: [String], idleHelperNames: [String]) -> Bool {
        let text = normalized(modelTranscript)
        let namesBusyHelper = usableHelperNames(busyHelperNames).contains { text.contains($0) }
        let namesIdleHelperOrHelperWord = usableHelperNames(idleHelperNames).contains { text.contains($0) }
            || text.range(of: "\\b(helper|helpers|dots|a dot|the dot)\\b", options: .regularExpression) != nil
        return namesBusyHelper && !namesIdleHelperOrHelperWord
    }

    /// Lowercased names long enough to look for inside a sentence. "Al"
    /// would be found inside every other word, so names under three
    /// letters are left out (the helper words still catch those).
    private static func usableHelperNames(_ helperNames: [String]) -> [String] {
        helperNames
            .map { normalized($0).trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 3 }
    }
}

/// One helper's latest job, for the recent work note.
struct DottieRecentHelperWork {
    let helperName: String
    let status: String
    let taskText: String
    let taskStartedAt: Date
    let touchedFilePaths: [String]
    let latestReply: String?
}

enum DottieRecentWorkNote {
    /// Jobs older than this are left out: the user means today's work.
    static let maximumAge: TimeInterval = 6 * 60 * 60
    static let maximumEntries = 3

    /// File paths named in a helper's steps or reply: "/Users/me/Budget.xlsx",
    /// "~/Desktop/report.docx", or a quoted path with spaces in it.
    static func filePaths(in text: String) -> [String] {
        var foundPaths: [String] = []
        let quotedPathPattern = "[\"'`]((?:~|/)[^\"'`\\n]+?\\.[A-Za-z0-9]{1,8})[\"'`]"
        let plainPathPattern = "(?:^|[\\s(=:])((?:~|/)(?:[^\\s\"'`,;()\\[\\]]+/)*[^\\s\"'`,;()\\[\\]/]+\\.[A-Za-z0-9]{1,8})(?=$|[\\s,;)\\].!?])"
        for pattern in [quotedPathPattern, plainPathPattern] {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in expression.matches(in: text, range: range) {
                guard let pathRange = Range(match.range(at: 1), in: text) else { continue }
                let path = String(text[pathRange])
                if !foundPaths.contains(path) { foundPaths.append(path) }
            }
        }
        return foundPaths
    }

    /// The note sent with a turn, or nil when no helper did anything lately.
    static func noteText(entries: [DottieRecentHelperWork], now: Date = Date()) -> String? {
        let recentEntries = entries
            .filter { now.timeIntervalSince($0.taskStartedAt) <= maximumAge }
            .sorted { $0.taskStartedAt > $1.taskStartedAt }
            .prefix(maximumEntries)
        guard !recentEntries.isEmpty else { return nil }
        var lines = ["[recent helper work] what your helpers did lately, newest first. when the user says \"it\", \"that file\" or \"what you just did\", they mean this. to open what a helper worked on, call open_helper_result with that helper's name; to change it more, start_helper with the same helper_name. the second brain is your memory, never the one to open or redo a helper's work."]
        for entry in recentEntries {
            var line = "- \(entry.helperName), \(entry.status): \"\(shortened(entry.taskText, to: 160))\""
            if !entry.touchedFilePaths.isEmpty {
                line += " files: \(entry.touchedFilePaths.prefix(4).joined(separator: ", "))"
            }
            if let latestReply = entry.latestReply, !latestReply.isEmpty {
                line += " said: \"\(shortened(latestReply, to: 160))\""
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    static func shortened(_ text: String, to maximumLength: Int) -> String {
        let singleLine = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return singleLine.count > maximumLength ? String(singleLine.prefix(maximumLength - 1)) + "…" : singleLine
    }
}
