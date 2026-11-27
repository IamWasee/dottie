//
//  DottieJevTextPieces.swift
//  leanring-buddy
//
//  The text a screen job will need typed, written once per job. Jev picks
//  moves but writes no text, so before, it could only type words lifted from
//  the request itself ("search for cats" → "cats"); "reply to Sam saying I'm
//  running late" or "fill in my name" had nothing to type. One quick text
//  model call (the Worker's "plan" role, GLM first) now writes the exact
//  pieces a person would type, and Jev chooses which to type and where, the
//  same way it chooses a button. Asked in the background while Jev starts,
//  only for jobs that look like they involve typing. The deciding and
//  reading are pure, so they can be unit tested.
//

import Foundation

enum DottieJevTextPieces {
    static let maximumPieces = 5
    static let maximumPieceLength = 300

    /// Words that say a job types something.
    private static let typingWords: Set<String> = [
        "type", "write", "search", "reply", "message", "email", "mail", "send", "text", "post", "comment",
        "fill", "enter", "name", "rename", "title", "caption", "note", "tweet", "dm", "say", "saying", "tell", "ask", "login", "address",
        // Forms: a new patient, client or contact is typed box by box.
        "form", "register", "details", "patient", "patients", "client", "clients", "customer", "customers", "contact", "contacts",
        "dob", "birth", "birthday", "phone"
    ]

    /// Whether the job likely types something worth a writing call.
    static func jobNeedsTyping(_ taskText: String) -> Bool {
        let words = Set(taskText.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
        return !words.isDisjoint(with: typingWords)
    }

    /// The model's instructions for one job.
    static func prompt(forTask taskText: String) -> String {
        """
        A Mac assistant is about to do this job on screen for its user: "\(taskText.prefix(600))"
        Write the exact text a person would type to do it: search words, a message or reply, a name, a title, an address. \
        Each piece on its own line, the words only, no quotes, no numbering, no explanation, at most \(maximumPieces) such lines. \
        Use the user's own words where they gave them; write a short natural message when they asked for one. \
        Never write a password or a code. If nothing needs typing, answer NONE.
        \(DottieFormFillPlan.promptAddition)
        """
    }

    /// The pieces out of the model's answer: one per line, list marks and
    /// quotes taken off, nothing empty, repeated or too long, capped.
    static func pieces(fromAnswer answerText: String) -> [String] {
        guard answerText.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() != "NONE" else { return [] }
        var seenPieces = Set<String>()
        var keptPieces: [String] = []
        for line in answerText.components(separatedBy: .newlines) {
            var piece = line.trimmingCharacters(in: .whitespaces)
            if let listMarkRange = piece.range(of: "^(?:[-*•]|\\d+[.)])\\s*", options: .regularExpression) {
                piece.removeSubrange(listMarkRange)
            }
            piece = piece.trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”‘’`"))
            // A form's box and value (DottieFormFillPlan), not text to type whole.
            if piece.uppercased().hasPrefix("BOX ") && piece.contains("=") { continue }
            guard !piece.isEmpty, piece.uppercased() != "NONE", piece.count <= maximumPieceLength,
                  seenPieces.insert(piece.lowercased()).inserted else { continue }
            keptPieces.append(piece)
            if keptPieces.count == maximumPieces { break }
        }
        return keptPieces
    }

    /// Pieces from the request and from the model together, the request's first, each once.
    static func merged(_ requestPieces: [String], _ writtenPieces: [String]) -> [String] {
        var seenPieces = Set<String>()
        return (requestPieces + writtenPieces).filter { seenPieces.insert($0.lowercased()).inserted }
    }

    /// What one writing call gave: text for Jev to type, and a form's boxes.
    struct Written: Equatable {
        let pieces: [String]
        let formBoxes: [DottieFormFillPlan.FormBox]
        static let nothing = Written(pieces: [], formBoxes: [])
    }

    /// Asks the Worker for the pieces and boxes, or nothing when it fails or takes too long.
    static func write(forTask taskText: String) async -> Written {
        let requestBody: [String: Any] = [
            "provider": "plan",
            "contents": [["role": "user", "parts": [["text": prompt(forTask: taskText)]]]],
            "generationConfig": ["maxOutputTokens": 500]
        ]
        guard let answerText = await DottieChat.send(requestBody, timeout: 10) else { return .nothing }
        let written = Written(pieces: pieces(fromAnswer: answerText), formBoxes: DottieFormFillPlan.formBoxes(fromAnswer: answerText))
        DottieLog.notice("⌨️ Wrote \(public: written.pieces.count) piece(s) of text and \(public: written.formBoxes.count) form box(es) for Jev")
        return written
    }
}
