//
//  TaskMatchingTests.swift
//  leanring-buddyTests
//
//  Which learned how-tos and plans fit a job. On celly's Mac (22 Nov) the
//  "bull and shit folder" ask and a Notes job both loaded the plan
//  "Open Finder and show the Downloads folder"; each case is checked here.
//

import Foundation
import Testing
@testable import Dottie

struct TaskMatchingTests {
    private let downloadsHowToName = "Show Downloads in Finder"
    private let downloadsHowToGoal = "Open Finder and show the Downloads folder"

    // MARK: Content words

    @Test func genericWordsAreLeftOut() {
        #expect(DottieTaskMatching.contentWords("Open Finder and show the Downloads folder") == ["finder", "download"])
        #expect(DottieTaskMatching.contentWords("open my bull and shit folder") == ["bull", "shit"])
        #expect(DottieTaskMatching.contentWords("open the app").isEmpty)
    }

    @Test func pluralsAndCaseAreFolded() {
        #expect(DottieTaskMatching.contentWords("NOTES") == DottieTaskMatching.contentWords("note"))
        // Short words and double s are kept as written.
        #expect(DottieTaskMatching.contentWords("bus glass") == ["bus", "glass"])
        #expect(DottieTaskMatching.contentWords("rank 3") == ["rank", "3"])
    }

    // MARK: Learned plans

    @Test func theFolderAskAndTheNotesJobDontGetTheDownloadsPlan() {
        #expect(DottieTaskMatching.taskSimilarity(downloadsHowToGoal, "open my bull and shit folder") < 0.6)
        #expect(DottieTaskMatching.taskSimilarity(downloadsHowToGoal, "open Notes and make a TEST note that says hello") < 0.6)
        #expect(DottieTaskMatching.taskSimilarity(downloadsHowToGoal, "open notes") == 0)
    }

    @Test func theSameJobInOtherWordsGetsThePlan() {
        #expect(DottieTaskMatching.taskSimilarity(downloadsHowToGoal, "show my downloads in finder") >= 0.6)
        #expect(DottieTaskMatching.taskSimilarity("search kaggle and open my competitions", "open kaggle, search, go to competitions") >= 0.6)
    }

    @Test func aShortAskDoesntFitEveryLongerJobSharingAWord() {
        // One shared word out of five is not the same job.
        #expect(DottieTaskMatching.taskSimilarity("open kaggle", "open kaggle competitions rsna knee rank") < 0.6)
    }

    @Test func jobsWithNoContentWordsMatchNothing() {
        #expect(DottieTaskMatching.taskSimilarity("open it", "open it") == 0)
        #expect(DottieTaskMatching.taskSimilarity("", downloadsHowToGoal) == 0)
    }

    // MARK: Watched how-tos

    private func fits(_ taskText: String, frontApp: String?) -> Bool {
        DottieTaskMatching.howToFits(taskText: taskText, frontmostAppName: frontApp,
                                     howToName: downloadsHowToName, howToGoal: downloadsHowToGoal, howToAppName: "Finder")
    }

    @Test func beingInTheSameAppIsNotEnough() {
        #expect(!fits("open my bull and shit folder", frontApp: "Finder"))
        #expect(!fits("open Notes and make a TEST note", frontApp: "Finder"))
        #expect(!fits("rename this file to report", frontApp: "Finder"))
    }

    @Test func namingTheAppIsNotEnoughEither() {
        #expect(!fits("open finder", frontApp: nil))
        #expect(!fits("in finder open my bull and shit folder", frontApp: nil))
    }

    @Test func aJobAboutTheSameThingInTheAppFits() {
        #expect(fits("show my downloads", frontApp: "Finder"))
        #expect(fits("open downloads in finder", frontApp: "Safari"))
    }

    @Test func twoSharedTopicWordsFitWithoutTheApp() {
        let photoHowToFits = DottieTaskMatching.howToFits(taskText: "export the vacation photos", frontmostAppName: nil,
                                                          howToName: "Export vacation photos", howToGoal: "Save the album as JPEGs",
                                                          howToAppName: "Photos")
        #expect(photoHowToFits)
    }

    @Test func theAppsOwnNameDoesntCountAsATopicWord() {
        // "notes" is the app's name, not what the how-to is about.
        let notesHowToFits = DottieTaskMatching.howToFits(taskText: "open notes", frontmostAppName: "Notes",
                                                          howToName: "Move a note into a folder", howToGoal: "File a Notes note under Work",
                                                          howToAppName: "Notes")
        #expect(notesHowToFits == false)
        let movingFits = DottieTaskMatching.howToFits(taskText: "move my TEST note to the Work folder", frontmostAppName: "Notes",
                                                      howToName: "Move a note into a folder", howToGoal: "File a Notes note under Work",
                                                      howToAppName: "Notes")
        #expect(movingFits)
    }
}
