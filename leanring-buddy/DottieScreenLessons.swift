//
//  DottieScreenLessons.swift
//  leanring-buddy
//
//  What screen jobs learned last time. When a job finishes, the model can
//  leave a one-line tip ("Instagram: after typing a name in the DM search,
//  click the person in the list; return does nothing"), and a job that runs
//  out of steps leaves a note about what it kept repeating. The next job in
//  the same app or site starts with those tips, so Dottie gets better at
//  the user's own apps over time.
//

import Foundation

@MainActor
final class DottieScreenLessons {
    static let shared = DottieScreenLessons()

    private struct Lesson: Codable {
        let text: String
        let task: String
        let appName: String?
        let createdAt: Date
    }

    private static let maximumLessons = 120
    private static let lessonsPerJob = 6

    private var lessons: [Lesson] = []
    private let fileURL: URL

    private init() {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folderURL = applicationSupportURL.appendingPathComponent("Dottie", isDirectory: true)
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        fileURL = folderURL.appendingPathComponent("screen-lessons.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let savedData = try? Data(contentsOf: fileURL) {
            lessons = (try? decoder.decode([Lesson].self, from: savedData)) ?? []
        }
    }

    func add(_ text: String, task: String, appName: String?) {
        let trimmedText = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
        guard !trimmedText.isEmpty, !lessons.contains(where: { $0.text == trimmedText }) else { return }
        lessons.append(Lesson(text: trimmedText, task: String(task.prefix(200)), appName: appName, createdAt: Date()))
        if lessons.count > Self.maximumLessons {
            lessons.removeFirst(lessons.count - Self.maximumLessons)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(lessons) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Tips from earlier jobs that share an app or words with this one,
    /// newest first. Empty when there are none.
    func promptText(forTask task: String, frontmostAppName: String?) -> String {
        let taskWords = Set(Self.words(in: task + " " + (frontmostAppName ?? "")))
        guard !taskWords.isEmpty else { return "" }
        let relevantLessons = lessons.reversed().filter { lesson in
            let lessonWords = Set(Self.words(in: lesson.task + " " + (lesson.appName ?? "") + " " + lesson.text))
            return !taskWords.isDisjoint(with: lessonWords)
        }.prefix(Self.lessonsPerJob)
        guard !relevantLessons.isEmpty else { return "" }
        return "\nTips from your earlier jobs like this one (use them, but trust the screen):\n"
            + relevantLessons.map { "- \($0.text)" }.joined(separator: "\n") + "\n"
    }

    /// Meaningful words: app and site names, nouns, not filler.
    private static let fillerWords: Set<String> = [
        "the", "and", "then", "open", "go", "to", "my", "a", "an", "on", "in", "of", "for", "it", "is",
        "click", "and", "with", "me", "can", "you", "please", "that", "this", "write", "send", "hit", "type",
        "find", "search", "show", "tell", "what", "from", "into", "at", "up", "down", "scroll"
    ]

    private static func words(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !fillerWords.contains($0) }
    }
}
