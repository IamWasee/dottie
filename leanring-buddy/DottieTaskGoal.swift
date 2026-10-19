//
//  DottieTaskGoal.swift
//  leanring-buddy
//
//  What a screen job is really for, and how Dottie knows it's finished.
//  "Sign in with this account" isn't done when the account is clicked; it's
//  done when the account shows as signed in. So before a long job starts,
//  the request becomes a goal, a "done when" check and a short plan, and
//  the runner (DottieScreenTaskRunner) works until the check passes.
//
//  Cheapest first, so simple asks stay instant:
//    1. Sorting short from long is done here, on the Mac, from the words
//       ("scroll down", "click that" are short; "sign in", "and then",
//       "send it" are long). Unsure ones fall back to Apple's on-device
//       model (DottieModelPicker.isSimpleScreenJob).
//    2. Common goals (signing in, sending, downloading, installing,
//       paying...) come with a ready "done when" and plan from the table
//       below, with no model call at all.
//    3. A plan that worked before for a similar job comes from the screen
//       lessons (DottieScreenLessons.learnedPlan).
//    4. Anything else: the model writes the plan itself in the same
//       request as its first step (the runner's `plan` action), so it costs
//       no extra call.
//
//  Also here: the bridge for questions a job asks the user (which account,
//  a code), and the voice tool that passes the answer back.
//

import AppKit
import Foundation
import Vision

// MARK: - The goal

/// A long job's goal, how to tell it's done, and the plan to get there.
struct DottieTaskGoal {
    enum Source: String {
        /// From the table of common goals below.
        case template
        /// From a plan that worked before (DottieScreenLessons).
        case learned
        /// Written by the model in the job's first step.
        case model
    }

    var goal: String
    /// What the screen shows once it's really done.
    var doneWhen: String
    var steps: [String]
    var currentStepIndex: Int = 0
    /// Words that, while they're still on screen, mean it isn't done yet
    /// ("Enter your password"). Read on the Mac with text recognition.
    var notDoneSigns: [String] = []
    var source: Source
    /// The lesson this plan came from, so the job's outcome can score it.
    var learnedLessonID: UUID?

    var currentStepText: String? {
        steps.indices.contains(currentStepIndex) ? steps[currentStepIndex] : nil
    }

    /// The goal and plan for the model, with ticks for done steps.
    var promptText: String {
        var lines = ["Goal: \(goal)"]
        if !doneWhen.isEmpty { lines.append("Done when: \(doneWhen)") }
        if !steps.isEmpty {
            lines.append("Plan (✓ done, → now):")
            for (index, step) in steps.enumerated() {
                let marker = index < currentStepIndex ? "✓" : (index == currentStepIndex ? "→" : " ")
                lines.append("\(marker) \(index + 1). \(step)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Sorting and common goals

/// Plain text checks, so any thread can use them.
enum DottieTaskGoals {
    enum Size {
        /// One quick action: no plan, no done check, no extra calls.
        case short
        /// Needs a goal, a plan and a done check.
        case long
        /// The words don't say; the on-device model or the model tier decides.
        case unsure
    }

    /// A common goal: the words that ask for it, and what done looks like.
    private struct Template {
        let pattern: String
        let goal: String
        let doneWhen: String
        let steps: [String]
        var notDoneSigns: [String] = []
    }

    /// Checked in order; the first match wins. Patterns are ICU regular
    /// expressions over the lowercased request.
    private static let templates: [Template] = [
        Template(
            pattern: #"\b(sign|log)\s*(me\s+)?(back\s+)?(in|into|on|w|with)\b|\blogin\b|\bsignin\b|\buse (this|that|my) (acc|account)\b|\bcontinue (with|as)\b|\bswitch (to )?(my |the |this |that )?(other )?(acc|account)\b"#,
            goal: "Get the user signed in with the account they mean",
            doneWhen: "signed in: the account's picture, name or email shows in the app or site, and no sign-in, password, code or 'choose an account' page is left",
            steps: [
                "Open the sign-in page or account picker",
                "Pick the account the user means",
                "Go through 'continue as', consent or 'stay signed in' screens",
                "Use the password the browser offers; ask only for a code or password nobody saved",
                "Check the account shows as signed in"
            ],
            notDoneSigns: [
                "enter your password", "choose an account", "verify it's you", "verify it’s you", "2-step verification",
                "enter the code", "enter code", "use your passkey", "confirm it's you", "confirm it’s you", "sign in to continue"
            ]
        ),
        Template(
            pattern: #"\b(sign|log)\s*(me\s+)?out\b|\blogout\b"#,
            goal: "Sign the user out",
            doneWhen: "signed out: a sign-in button or page shows instead of the account",
            steps: ["Open the account menu", "Choose sign out", "Check it shows signed out"]
        ),
        Template(
            pattern: #"\b(sign up|signup|create (an |a new )?(account|acc)|register)\b"#,
            goal: "Create the account the user asked for",
            doneWhen: "the account is created: you're in it, or a 'check your email' or welcome page shows",
            steps: ["Open the sign-up page", "Fill in the details the user gave", "Ask for anything missing", "Submit", "Check it worked"]
        ),
        Template(
            pattern: #"\b(buy|purchase|checkout|check out|pay for|place (an |the |my )?order|order (a|an|the|me|some|my|this|that|it))\b"#,
            goal: "Place the order the user asked for",
            doneWhen: "the order is placed and an order confirmation shows",
            steps: ["Find the item", "Add it to the cart", "Go to checkout", "Ask the user before paying", "Check the confirmation shows"]
        ),
        Template(
            pattern: #"\b(send|reply|respond|dm|forward (it|this|that|the))\b"#,
            goal: "Send the message the user asked for",
            doneWhen: "the message shows as sent (in the conversation or the Sent folder), not still sitting in the text box",
            steps: ["Open the conversation or a new message", "Write the message", "Send it", "Check it shows as sent"]
        ),
        Template(
            pattern: #"\b(post (it|this|that|a|my)|tweet|comment on|publish)\b"#,
            goal: "Post what the user asked for",
            doneWhen: "the post or comment shows on the page as posted",
            steps: ["Open where it goes", "Write it", "Post it", "Check it shows as posted"]
        ),
        Template(
            pattern: #"\bdownload\b"#,
            goal: "Download what the user asked for",
            doneWhen: "the download has started or finished (it shows in the browser's downloads or a save dialog is done)",
            steps: ["Find the right file or button", "Start the download", "Check it's downloading"]
        ),
        Template(
            pattern: #"\b(install|reinstall)\b"#,
            goal: "Install what the user asked for",
            doneWhen: "it's installed: an Open button instead of Get or Install, or the installer says it's done",
            steps: ["Find it", "Start the install", "Go through the installer's screens", "Check it's done"]
        ),
        Template(
            pattern: #"\bjoin\b.*\b(meeting|call|zoom|meet|room|server|channel)\b"#,
            goal: "Get the user into the meeting or call",
            doneWhen: "the user is in: the call window shows, not a waiting or 'join now' screen",
            steps: ["Open the meeting link or app", "Choose join", "Check they're in"]
        ),
        Template(
            pattern: #"\bconnect\b.*\b(wi-?fi|bluetooth|airpods|headphones|speaker|network|vpn|printer)\b"#,
            goal: "Connect what the user asked for",
            doneWhen: "it shows as connected",
            steps: ["Open the right settings or menu", "Pick the device or network", "Check it shows connected"]
        ),
        Template(
            pattern: #"\b(turn on|turn off|switch on|switch off|enable|disable)\b"#,
            goal: "Change the setting the user asked for",
            doneWhen: "the setting shows as changed the way the user asked",
            steps: ["Open where the setting lives", "Change it", "Check it shows the new value"]
        ),
        Template(
            pattern: #"\b(fill (in|out)|submit|apply for|apply to)\b"#,
            goal: "Fill in and send the form the user asked for",
            doneWhen: "the form is submitted and a confirmation or the next page shows",
            steps: ["Open the form", "Fill in what the user gave", "Ask for anything missing", "Submit", "Check the confirmation"]
        ),
        Template(
            pattern: #"\b(book (a|an|the|me|my|it|this|that)|reserve|make a reservation|schedule (a|an|the|my|it|this|that))\b"#,
            goal: "Make the booking the user asked for",
            doneWhen: "the booking shows as confirmed",
            steps: ["Open the booking page", "Pick the details the user gave", "Ask before paying", "Confirm", "Check it's confirmed"]
        ),
        Template(
            pattern: #"\b(upload|attach)\b"#,
            goal: "Upload or attach the file the user asked for",
            doneWhen: "the file shows as uploaded or attached",
            steps: ["Open where it goes", "Choose the file", "Check it shows as attached"]
        ),
        Template(
            pattern: #"\b(delete|remove|unsubscribe|cancel my|cancel the)\b"#,
            goal: "Remove what the user asked for",
            doneWhen: "it's gone from the list, or a confirmation says it's done",
            steps: ["Find it", "Choose delete or cancel", "Confirm only what the user asked", "Check it's gone"]
        )
    ]

    /// First words of a request that's one quick action ("click that",
    /// "scroll down", "go back").
    private static let quickActionStarts: [String] = [
        "click", "tap", "press", "hit", "scroll", "point", "show me where", "where is", "where's", "select", "pause",
        "play", "resume", "mute", "unmute", "go back", "go forward", "close", "refresh", "reload", "zoom", "open",
        "minimize", "maximize", "full screen", "fullscreen", "skip", "next", "previous", "stop", "highlight", "circle",
        "copy", "paste", "undo", "redo", "type"
    ]

    /// Words that mean several things in a row, or reading something back.
    private static let longJobMarkers: [String] = [
        " and ", " then ", " after ", " also ", ", ", " tell me ", " find ", " search ", " look up ", " check ", " compare ",
        " until ", " every ", " all the ", " each ", " what's ", " what is ", " how many ", " how much ", " which ", " who "
    ]

    /// Short or long from the words alone, with no model call.
    static func size(of taskText: String) -> Size {
        let lowercasedText = taskText.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let paddedText = " " + lowercasedText.replacingOccurrences(of: "\n", with: " ") + " "
        let hasLongJobMarker = longJobMarkers.contains { paddedText.contains($0) }
        let wordCount = lowercasedText.split(whereSeparator: { $0.isWhitespace }).count
        let request = strippedPoliteness(lowercasedText)
        // "click sign in" asks for the click itself, not for signing in.
        let clickVerbs = ["click", "tap", "press", "hit", "select"]
        if !hasLongJobMarker, wordCount <= 6, clickVerbs.contains(where: { request.hasPrefix($0 + " ") }) { return .short }
        if templateMatch(for: lowercasedText) != nil || hasLongJobMarker || wordCount > 12 { return .long }
        if wordCount <= 7, quickActionStarts.contains(where: { request.hasPrefix($0) }) { return .short }
        return .unsure
    }

    /// The ready-made goal for a common request, or nil.
    static func template(for taskText: String) -> DottieTaskGoal? {
        guard let template = templateMatch(for: taskText.lowercased()) else { return nil }
        return DottieTaskGoal(
            goal: template.goal,
            doneWhen: template.doneWhen,
            steps: template.steps,
            notDoneSigns: template.notDoneSigns,
            source: .template
        )
    }

    /// The "still not done" words for a request's common goal, if it has any.
    static func notDoneSigns(for taskText: String) -> [String] {
        templateMatch(for: taskText.lowercased())?.notDoneSigns ?? []
    }

    /// True when the user's words ask for a goal that one click doesn't
    /// finish ("sign in with this account"), as opposed to asking for the
    /// click itself ("click sign in").
    static func clickLeavesGoalUnfinished(request: String) -> Bool {
        let lowercasedRequest = request.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lowercasedRequest.isEmpty, templateMatch(for: lowercasedRequest) != nil else { return false }
        let strippedRequest = strippedPoliteness(lowercasedRequest)
        let justTheClick = ["click", "tap", "press", "hit", "select", "point", "show me", "where"]
        return !justTheClick.contains { strippedRequest.hasPrefix($0) }
    }

    private static func templateMatch(for lowercasedText: String) -> Template? {
        templates.first { lowercasedText.range(of: $0.pattern, options: .regularExpression) != nil }
    }

    /// "hey dottie can you please scroll down" → "scroll down".
    private static func strippedPoliteness(_ lowercasedText: String) -> String {
        var request = lowercasedText
        let openers = [
            "hey dottie", "dottie", "hey", "okay", "ok", "so", "please", "can you", "can u", "could you", "could u",
            "would you", "will you", "i want you to", "i need you to", "go ahead and", "just", "now", "for me", ","
        ]
        var didStrip = true
        while didStrip {
            didStrip = false
            request = request.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            for opener in openers where request.hasPrefix(opener + " ") || request == opener {
                request = String(request.dropFirst(opener.count))
                didStrip = true
            }
        }
        return request
    }

    // MARK: - Checking on the Mac

    /// The first "not done yet" sign readable on the screenshot, using
    /// Apple's on-device text recognition (no model call), or nil.
    static func visibleNotDoneSign(in image: CGImage, signs: [String]) async -> String? {
        guard !signs.isEmpty else { return nil }
        let screenText = await Task.detached(priority: .userInitiated) { () -> String in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            guard (try? handler.perform([request])) != nil else { return "" }
            return (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
                .lowercased()
        }.value
        guard !screenText.isEmpty else { return nil }
        return signs.first { screenText.contains($0.lowercased()) }
    }
}

// MARK: - Questions a job asks the user

/// A running screen job that needs something only the user knows (which
/// account, a code from their phone, okay to pay) waits here for the
/// answer, which comes back through answer_screen_job or the user's next
/// voice turn.
@MainActor
final class DottieScreenJobQuestions {
    static let shared = DottieScreenJobQuestions()

    private(set) var pendingQuestion: String?
    private var continuation: CheckedContinuation<String?, Never>?
    private var timeoutTask: Task<Void, Never>?

    var isWaitingForAnswer: Bool { continuation != nil }
    /// Dottie has said the question out loud, so the user's next turn can
    /// be the answer.
    private(set) var wasAskedAloud = false

    func noteAskedAloud() {
        if isWaitingForAnswer { wasAskedAloud = true }
    }

    /// Waits for the user's answer. nil when they don't answer in time or
    /// the job stops.
    func waitForAnswer(to question: String, timeoutSeconds: Double) async -> String? {
        resolve(with: nil)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                self.pendingQuestion = question
                self.continuation = continuation
                self.timeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    self?.resolve(with: nil)
                }
            }
        } onCancel: {
            Task { @MainActor in DottieScreenJobQuestions.shared.resolve(with: nil) }
        }
    }

    /// Hands the user's answer to the waiting job. False when none waits.
    @discardableResult
    func answer(_ answerText: String) -> Bool {
        let trimmedAnswer = answerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isWaitingForAnswer, !trimmedAnswer.isEmpty else { return false }
        resolve(with: trimmedAnswer)
        return true
    }

    /// Ends the wait with an answer, or nil for none.
    func resolve(with answerText: String?) {
        let waitingContinuation = continuation
        continuation = nil
        pendingQuestion = nil
        wasAskedAloud = false
        timeoutTask?.cancel()
        timeoutTask = nil
        waitingContinuation?.resume(returning: answerText)
    }
}

// MARK: - Voice tool

/// Lets voice Dottie pass the user's reply to a screen job that asked
/// something, and tells her to hand whole goals to the job.
@MainActor
enum DottieScreenGoalTools: DottieToolModule {
    static var tools: [DottieTool] {
        [
            DottieTool(
                name: "answer_screen_job",
                description: "Pass the user's reply to the on-screen job that just asked them something (which account, a code, a password, okay to go ahead, or that they did a step themselves). Use their words; the job carries on by itself.",
                parameters: [
                    "type": "OBJECT",
                    "properties": [
                        "answer": ["type": "STRING", "description": "The user's reply, exactly as they said it (a code or password letter for letter)."]
                    ],
                    "required": ["answer"]
                ],
                audiences: [.voice]
            ) { arguments in
                guard let answerText = arguments.dottieString("answer") else { return "no answer given." }
                guard DottieScreenJobQuestions.shared.answer(answerText) else {
                    return "no on-screen job is waiting for an answer right now."
                }
                return "passed it on; the job carries on. say okay in two or three words, nothing more."
            }
        ]
    }

    static var voicePromptSection: String {
        """
        finishing the whole job: work out what the user really wants done, not just the first click. "sign in with this account" means get them signed in, not click the account; "send this to sam" means sent. if getting there takes more than one action, call do_task_on_screen once with the whole goal in their words (plus names and details from the conversation). don't split one goal into several calls, don't do its first step yourself, and don't narrate its steps. the job works out the steps and asks only when it must; when it asks the user something, pass their reply to answer_screen_job.
        """
    }
}
