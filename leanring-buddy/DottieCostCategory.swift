//
//  DottieCostCategory.swift
//  leanring-buddy
//
//  What each paid model call is for, so cost can be read per feature:
//  voice asks, screen job steps, plans, Jev, pointing, drawings, helpers and
//  the rest. Every request to the Worker carries its category in the
//  `x-dottie-cost-category` header (ClickyWorkerConfiguration adds it from
//  the file that made the request), the Worker adds what the answer cost to
//  that category for the install and for everyone, and the app's own
//  "💵 usage" log lines name it too. A file not listed here shows up as
//  "other:<file>", so a new feature is never lumped in unseen. Foundation
//  only, so it can be unit tested.
//

import Foundation

nonisolated enum DottieCostCategory {
    /// The header the Worker reads the category from.
    static let headerName = "x-dottie-cost-category"

    /// Every category, with the files whose requests count toward it.
    static let filesByCategory: [String: [String]] = [
        "voice": ["DottieTalker", "GeminiAPI", "CompanionManager", "CompanionManager+ClassicVoice", "CompanionManager+TypedAndInstant"],
        "screen_job_steps": ["DottieScreenTaskRunner", "DottieScreenJobClaudeBrain"],
        "screen_job_plan": ["DottieScreenJobGuesser", "DottieTaskGoal"],
        "jev": ["DottieJev", "DottieJevDriver"],
        "tv_jobs": ["DottieTVTaskRunner"],
        "guides": ["DottieGuide", "DottieGuideBrain"],
        "pointing": ["PointingRefiner", "PointingPrecision", "DottieReadClosely"],
        "drawing_and_teaching": ["DottieTeaching", "DottieSketchArtist", "DottieNotesBoard", "DottieCodeOnScreen"],
        "watch_and_learn": ["DottieWatchAndLearn"],
        "smart_replays": ["DottieSmartReplays", "DottieReplays"],
        "meetings": ["DottieMeetingLiveHelp", "DottieMeetingRecorder"],
        "memory": ["DottieEpisodicMemory", "DottieEpisodicMemoryRecall", "DottieBrain", "DottieImageMemory"],
        "phone": ["DottiePhoneBridge", "DottiePhoneFiles"],
        "web_search": ["DottieWebSearch"],
        "smart_home": ["DottieSmartHome", "DottieTV"],
        "everyday": ["DottieFixText", "DottieWatches", "DottieFocus", "DottieFolderCleanup"],
        "games": ["DottieGames"],
        "personality": ["DottieCustomPersonality"],
        "self_check": ["DottieSelfCheck"]
    ]

    private static let categoryByFileStem: [String: String] = {
        var mapping: [String: String] = [:]
        for (category, fileStems) in filesByCategory {
            for fileStem in fileStems { mapping[fileStem] = category }
        }
        return mapping
    }()

    /// The category for a request made in `callerFile` (a #fileID such as
    /// "Dottie/DottieTalker.swift").
    static func category(forCallerFile callerFile: String) -> String {
        let fileName = (callerFile as NSString).lastPathComponent
        let fileStem = (fileName as NSString).deletingPathExtension
        if let category = categoryByFileStem[fileStem] { return category }
        let safeStem = fileStem.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "_" || $0 == "-" }
        return "other:" + (safeStem.isEmpty ? "unknown" : String(safeStem.prefix(50)))
    }
}
