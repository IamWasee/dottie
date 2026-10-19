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
//  Each tip keeps a score, like reinforcement learning without retraining
//  the model: every job that used it and got done counts as a win, every
//  job that used it and failed counts as a loss. Tips that keep working
//  come first and say so; tips that keep failing are dropped.
//
//  A long job that got done also leaves its plan (goal, "done when" and
//  steps, see DottieTaskGoal), so the next similar ask starts with a plan
//  that's known to work and shows it in the notch straight away.
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
        // Optional so tips saved before scores existed still load.
        var id: UUID?
        var successes: Int?
        var failures: Int?
        /// Set on a plan that worked for a long job (DottieTaskGoal).
        var goal: String?
        var doneWhen: String?
        var planSteps: [String]?

        var isPlan: Bool { !(planSteps ?? []).isEmpty }

        var winCount: Int { successes ?? 0 }
        var lossCount: Int { failures ?? 0 }

        /// How likely this tip is to help, from 0 to 1. Untried tips sit at
        /// 0.5; each win or loss moves it.
        var score: Double { Double(winCount + 1) / Double(winCount + lossCount + 2) }

        /// Tried at least three times and it failed most of them.
        var hasProvenUseless: Bool { lossCount >= 3 && score < 0.3 }
    }

    /// The tips one job was given, so its outcome can score them.
    struct Selection {
        let promptText: String
        let lessonIDs: [UUID]
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
        for index in lessons.indices where lessons[index].id == nil {
            lessons[index].id = UUID()
        }
    }

    var count: Int { lessons.count }

    /// Saves a new tip. One from a job that just worked starts with a win.
    func add(_ text: String, task: String, appName: String?, cameFromSuccess: Bool = false) {
        let trimmedText = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
        guard !trimmedText.isEmpty, !lessons.contains(where: { $0.text == trimmedText }) else { return }
        add(lesson: Lesson(
            text: trimmedText, task: String(task.prefix(200)), appName: appName, createdAt: Date(),
            id: UUID(), successes: cameFromSuccess ? 1 : 0, failures: 0
        ))
    }

    private func add(lesson: Lesson) {
        lessons.append(lesson)
        if lessons.count > Self.maximumLessons {
            // Make room by dropping the weakest tips, oldest first.
            let overflowCount = lessons.count - Self.maximumLessons
            let weakestFirst = lessons.indices.sorted { firstIndex, secondIndex in
                let firstScore = lessons[firstIndex].score
                let secondScore = lessons[secondIndex].score
                if firstScore != secondScore { return firstScore < secondScore }
                return firstIndex < secondIndex
            }
            let removedIndices = Set(weakestFirst.prefix(overflowCount))
            lessons = lessons.indices.filter { !removedIndices.contains($0) }.map { lessons[$0] }
        }
        save()
    }

    /// The reward: the job that was given these tips got done, or didn't.
    func recordOutcome(lessonIDs: [UUID], succeeded: Bool) {
        guard !lessonIDs.isEmpty else { return }
        for index in lessons.indices {
            guard let id = lessons[index].id, lessonIDs.contains(id) else { continue }
            if succeeded {
                lessons[index].successes = lessons[index].winCount + 1
            } else {
                lessons[index].failures = lessons[index].lossCount + 1
            }
        }
        let forgottenCount = lessons.filter(\.hasProvenUseless).count
        lessons.removeAll(where: \.hasProvenUseless)
        if forgottenCount > 0 { print("🧠 Forgot \(forgottenCount) screen tip(s) that kept failing") }
        save()
    }

    // MARK: - Plans that worked

    /// Keeps the plan of a long job that got done, replacing the plan of
    /// the same job in the same app.
    func addPlan(_ taskGoal: DottieTaskGoal, task: String, appName: String?) {
        let steps = taskGoal.steps.map { String($0.prefix(120)) }.filter { !$0.isEmpty }
        guard !steps.isEmpty else { return }
        if let existingIndex = lessons.firstIndex(where: { lesson in
            lesson.isPlan && lesson.appName == appName && DottieReplayStore.wordOverlap(lesson.task, task) >= 0.75
        }) {
            lessons[existingIndex].planSteps = steps
            lessons[existingIndex].goal = taskGoal.goal
            lessons[existingIndex].doneWhen = taskGoal.doneWhen
            if taskGoal.learnedLessonID != lessons[existingIndex].id {
                // Its own win is counted by recordOutcome when it was used.
                lessons[existingIndex].successes = lessons[existingIndex].winCount + 1
            }
            save()
            return
        }
        var planLesson = Lesson(
            text: "Plan that worked for \"\(task.prefix(80))\": " + steps.joined(separator: "; "),
            task: String(task.prefix(200)), appName: appName, createdAt: Date(),
            id: UUID(), successes: 1, failures: 0
        )
        planLesson.goal = taskGoal.goal
        planLesson.doneWhen = taskGoal.doneWhen
        planLesson.planSteps = steps
        add(lesson: planLesson)
    }

    /// The plan that worked for the most similar earlier job, preferring
    /// the same app, or nil when none is close enough.
    func learnedPlan(forTask task: String, appName: String?) -> DottieTaskGoal? {
        let candidates = lessons.compactMap { lesson -> (Lesson, Double)? in
            guard lesson.isPlan, !lesson.hasProvenUseless else { return nil }
            if let lessonApp = lesson.appName, let appName, lessonApp != appName { return nil }
            let overlap = DottieReplayStore.wordOverlap(lesson.task, task)
            return overlap >= 0.6 ? (lesson, overlap) : nil
        }
        guard let best = candidates.max(by: { first, second in
            first.1 == second.1 ? first.0.score < second.0.score : first.1 < second.1
        })?.0 else { return nil }
        return DottieTaskGoal(
            goal: best.goal ?? best.task,
            doneWhen: best.doneWhen ?? "",
            steps: best.planSteps ?? [],
            source: .learned,
            learnedLessonID: best.id
        )
    }

    func forgetAll() {
        lessons = []
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(lessons) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Tips from earlier jobs that share an app or words with this one: the
    /// best-scoring first, then the newest. Empty when there are none.
    func select(forTask task: String, frontmostAppName: String?) -> Selection {
        let taskWords = Set(Self.words(in: task + " " + (frontmostAppName ?? "")))
        guard !taskWords.isEmpty else { return Selection(promptText: "", lessonIDs: []) }
        var candidates: [(lesson: Lesson, order: Int)] = []
        for (order, lesson) in lessons.enumerated() where !lesson.isPlan {
            let lessonWords = Set(Self.words(in: lesson.task + " " + (lesson.appName ?? "") + " " + lesson.text))
            if !taskWords.isDisjoint(with: lessonWords) { candidates.append((lesson, order)) }
        }
        candidates.sort { first, second in
            if first.lesson.score != second.lesson.score { return first.lesson.score > second.lesson.score }
            return first.order > second.order
        }
        let chosen = candidates.prefix(Self.lessonsPerJob).map(\.lesson)
        guard !chosen.isEmpty else { return Selection(promptText: "", lessonIDs: []) }
        let lines = chosen.map { lesson -> String in
            let triedCount = lesson.winCount + lesson.lossCount
            let record = triedCount == 0 ? "" : " (worked \(lesson.winCount) of \(triedCount) times)"
            return "- \(lesson.text)\(record)"
        }
        return Selection(
            promptText: "\nTips from your earlier jobs like this one, best first (use them, but trust the screen):\n"
                + lines.joined(separator: "\n") + "\n",
            lessonIDs: chosen.compactMap(\.id)
        )
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
