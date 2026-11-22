//
//  CostCategoryTests.swift
//  leanring-buddyTests
//
//  Every paid request names the feature it was for, so cost can be read
//  per feature on the Worker and in the log.
//

import Foundation
import Testing
@testable import Dottie

struct CostCategoryTests {
    @Test func eachFeatureFileHasItsCategory() {
        #expect(DottieCostCategory.category(forCallerFile: "Dottie/DottieTalker.swift") == "voice")
        #expect(DottieCostCategory.category(forCallerFile: "Dottie/DottieScreenTaskRunner.swift") == "screen_job_steps")
        #expect(DottieCostCategory.category(forCallerFile: "Dottie/DottieScreenJobGuesser.swift") == "screen_job_plan")
        #expect(DottieCostCategory.category(forCallerFile: "Dottie/DottieJev.swift") == "jev")
        #expect(DottieCostCategory.category(forCallerFile: "Dottie/PointingRefiner.swift") == "pointing")
        #expect(DottieCostCategory.category(forCallerFile: "Dottie/DottieTeaching.swift") == "drawing_and_teaching")
        #expect(DottieCostCategory.category(forCallerFile: "Dottie/DottieWatchAndLearn.swift") == "watch_and_learn")
        #expect(DottieCostCategory.category(forCallerFile: "Dottie/DottieMeetingLiveHelp.swift") == "meetings")
    }

    @Test func anUnlistedFileIsNamedNotLumpedIn() {
        #expect(DottieCostCategory.category(forCallerFile: "Dottie/DottieBrandNewThing.swift") == "other:dottiebrandnewthing")
        #expect(DottieCostCategory.category(forCallerFile: "") == "other:unknown")
    }

    @Test func noFileIsInTwoCategories() {
        let allStems = DottieCostCategory.filesByCategory.values.flatMap { $0 }
        #expect(allStems.count == Set(allStems).count)
    }

    @Test func categoriesOnlyUseCharactersTheWorkerKeeps() {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_:+-")
        for category in DottieCostCategory.filesByCategory.keys {
            #expect(category.unicodeScalars.allSatisfy { allowed.contains($0) })
        }
    }

    @Test func theUsageLogLineNamesTheCategory() {
        let usage = DottieAskUsage(provider: "glm", model: "glm-5.3-flash", inputTokens: 10, outputTokens: 2, seconds: 1, estimatedDollars: nil)
        #expect(usage.logText(askNumber: 2, area: "Screen tasks and games", costCategory: "screen_job_steps").contains("Screen tasks and games [screen_job_steps]"))
        #expect(!usage.logText(askNumber: 2, area: "Voice").contains("["))
    }
}
