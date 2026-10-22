//
//  DottieAppLessons.swift
//  leanring-buddy
//
//  What the user taught Dottie about their apps when she got one wrong
//  ("no, in CapCut it's Audio, then Voice isolation, on the right"). Each
//  lesson is kept under the app's name and handed to the guide whenever it
//  teaches that app, so the same mistake isn't made twice.
//
//  Saved in Application Support/Dottie/AppLessons.json.
//

import AppKit
import Foundation

@MainActor
final class DottieAppLessons {
    static let shared = DottieAppLessons()

    private static let maximumLessonsPerApp = 30
    private let fileURL: URL
    /// App name (lowercased) to lessons, oldest first.
    private var lessonsByAppName: [String: [String]]

    private init() {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dottieFolderURL = applicationSupportURL.appendingPathComponent("Dottie", isDirectory: true)
        try? FileManager.default.createDirectory(at: dottieFolderURL, withIntermediateDirectories: true)
        fileURL = dottieFolderURL.appendingPathComponent("AppLessons.json")
        lessonsByAppName = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
    }

    private static func key(for appName: String) -> String {
        appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func save(_ lesson: String, forApp appName: String) {
        let trimmedLesson = lesson.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLesson.isEmpty, !Self.key(for: appName).isEmpty else { return }
        var lessons = lessonsByAppName[Self.key(for: appName)] ?? []
        lessons.removeAll { $0.caseInsensitiveCompare(trimmedLesson) == .orderedSame }
        lessons.append(trimmedLesson)
        lessonsByAppName[Self.key(for: appName)] = Array(lessons.suffix(Self.maximumLessonsPerApp))
        guard let lessonsData = try? JSONEncoder().encode(lessonsByAppName) else { return }
        try? lessonsData.write(to: fileURL, options: .atomic)
    }

    func lessons(forApp appName: String) -> [String] {
        lessonsByAppName[Self.key(for: appName)] ?? []
    }
}

// MARK: - Voice tool

@MainActor
enum DottieAppLessonTools: DottieToolModule {
    static var tools: [DottieTool] {
        [
            DottieTool(
                name: "save_app_lesson",
                description: "Save how an app really works after the user corrects you ('no, it's under Audio on the right', 'that button doesn't exist in my version'). Kept per app and used every time you teach that app, so the same mistake isn't made again.",
                parameters: [
                    "type": "OBJECT",
                    "properties": [
                        "app": ["type": "STRING", "description": "The app's name, like CapCut. Leave out for the app in front."],
                        "lesson": ["type": "STRING", "description": "The right way, standing on its own: 'To isolate a voice: select the clip, then Audio on the right, then Voice isolation.'"]
                    ],
                    "required": ["lesson"]
                ],
                audiences: [.voice]
            ) { arguments in
                let appName = arguments.dottieString("app")
                    ?? NSWorkspace.shared.frontmostApplication?.localizedName
                    ?? ""
                guard let lesson = arguments.dottieString("lesson"), !appName.isEmpty else {
                    return "say what the right way is, and for which app."
                }
                DottieAppLessons.shared.save(lesson, forApp: appName)
                return "saved for \(appName). say thanks for the correction in a few words."
            }
        ]
    }
}
