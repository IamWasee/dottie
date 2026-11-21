//
//  NamedPlaceFinderTests.swift
//  leanring-buddyTests
//
//  Unit tests for DottieNamedPlaceFinder: the folders and files a helper's
//  task names are found before it starts, even when the user's file name
//  is only close to the real one. Also which connected apps Gemini CLI
//  helpers leave out because they repeat its own tools.
//

import Foundation
import Testing
@testable import Dottie

struct NamedPlaceFinderNameTests {
    @Test func quotedNamesAndFolderPhrasesAreFound() {
        let taskText = "In the 'bull and shit' folder, open the 'invoice cleanup.demo.xlsx' file."
        #expect(DottieNamedPlaceFinder.spokenNames(in: taskText) == ["bull and shit", "invoice cleanup.demo.xlsx"])
        #expect(DottieNamedPlaceFinder.spokenNames(in: "tidy up the school stuff folder please") == ["school stuff"])
        #expect(DottieNamedPlaceFinder.spokenNames(in: "look in the receipts folder") == ["receipts"])
    }

    @Test func fileNamesAreToldApartFromFolderNames() {
        #expect(DottieNamedPlaceFinder.isFileName("invoice cleanup.demo.xlsx"))
        #expect(DottieNamedPlaceFinder.isFileName("Budget.numbers"))
        #expect(DottieNamedPlaceFinder.isFileName("report.docx"))
        #expect(DottieNamedPlaceFinder.isFileName("bull and shit") == false)
        #expect(DottieNamedPlaceFinder.isFileName("version 1.2") == false)
    }

    @Test func closeFileNamesMatchAndTheExactestWins() {
        let asked = "invoice cleanup.demo.xlsx"
        let real = DottieNamedPlaceFinder.similarity(askedName: asked, realName: "Invoice Cleanup (Dottie demo).xlsx")
        let copy = DottieNamedPlaceFinder.similarity(askedName: asked, realName: "Invoice Cleanup (Dottie demo) 2.xlsx")
        let other = DottieNamedPlaceFinder.similarity(askedName: asked, realName: "snoopy.png")
        #expect(real > 0.9)
        #expect(real > copy)
        #expect(other < 0.5)
    }
}

struct NamedPlaceFinderFolderTests {
    private func makeHomeFolder() throws -> URL {
        let homeURL = FileManager.default.temporaryDirectory.appendingPathComponent("NamedPlaceFinder-\(UUID().uuidString)", isDirectory: true)
        let folderURL = homeURL.appendingPathComponent("bull and shit", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        for fileName in ["Invoice Cleanup (Dottie demo) 2.xlsx", "Invoice Cleanup (Dottie demo).xlsx", "notes.txt"] {
            try Data("x".utf8).write(to: folderURL.appendingPathComponent(fileName))
        }
        return homeURL
    }

    @Test func theNamedFolderAndFileAreFoundWhateverTheirCase() throws {
        let homeURL = try makeHomeFolder()
        defer { try? FileManager.default.removeItem(at: homeURL) }
        let foundFolders = DottieNamedPlaceFinder.findFolders(
            in: "In the 'Bull And Shit' folder, open 'invoice cleanup.demo.xlsx' and fix the names.",
            searchFolderURLs: [homeURL]
        )
        #expect(foundFolders.count == 1)
        #expect(foundFolders.first?.folderURL.lastPathComponent == "bull and shit")
        #expect(foundFolders.first?.matchedFileName == "Invoice Cleanup (Dottie demo).xlsx")
        #expect(foundFolders.first?.fileNames.first == "Invoice Cleanup (Dottie demo).xlsx")

        let note = try #require(DottieNamedPlaceFinder.noteText(for: foundFolders))
        #expect(note.contains("bull and shit/Invoice Cleanup (Dottie demo).xlsx"))
        #expect(note.contains("no need to search"))
    }

    @Test func aSpokenFolderNameFindsTheDashedFolder() throws {
        let homeURL = try makeHomeFolder()
        defer { try? FileManager.default.removeItem(at: homeURL) }
        try FileManager.default.createDirectory(at: homeURL.appendingPathComponent("Dottie-test-sandbox"), withIntermediateDirectories: true)
        let foundFolders = DottieNamedPlaceFinder.findFolders(in: "In the Dottie test sandbox folder, open sales messy", searchFolderURLs: [homeURL])
        #expect(foundFolders.first?.folderURL.lastPathComponent == "Dottie-test-sandbox")
        #expect(DottieNamedPlaceFinder.folderKey("bull_and-shit") == DottieNamedPlaceFinder.folderKey("Bull And Shit"))
    }

    @Test func nothingIsAddedWhenNoNamedFolderExists() throws {
        let homeURL = try makeHomeFolder()
        defer { try? FileManager.default.removeItem(at: homeURL) }
        #expect(DottieNamedPlaceFinder.findFolders(in: "open the 'taxes' folder", searchFolderURLs: [homeURL]).isEmpty)
        #expect(DottieNamedPlaceFinder.findFolders(in: "make me a website", searchFolderURLs: [homeURL]).isEmpty)
        #expect(DottieNamedPlaceFinder.noteText(for: []) == nil)
    }
}

struct GeminiHelperToolDietTests {
    @Test func desktopCommanderIsLeftOutForGeminiHelpers() {
        #expect(GeminiCLIAgentRuntime.repeatsBuiltInTools(serverName: "desktop-commander"))
        #expect(GeminiCLIAgentRuntime.repeatsBuiltInTools(serverName: "Desktop_Commander"))
        #expect(GeminiCLIAgentRuntime.repeatsBuiltInTools(serverName: "computer-use") == false)
        #expect(GeminiCLIAgentRuntime.repeatsBuiltInTools(serverName: "notion") == false)
    }
}

/// "open my bowl and shit folder" opens ~/bull and shit on the Mac, with no model.
struct SpokenFolderOpeningTests {
    @Test func readsTheFolderNameFromAnOpenAsk() {
        #expect(DottieNamedPlaceFinder.spokenFolderName(fromOpenTarget: "bowl and shit folder") == "bowl and shit")
        #expect(DottieNamedPlaceFinder.spokenFolderName(fromOpenTarget: "folder bowl and shit") == "bowl and shit")
        #expect(DottieNamedPlaceFinder.spokenFolderName(fromOpenTarget: "the folder called invoices") == "invoices")
        #expect(DottieNamedPlaceFinder.spokenFolderName(fromOpenTarget: "spotify") == nil)
    }

    @Test func aMisheardWordStillFindsTheFolder() {
        let realNames = ["bull and shit", "Documents", "Dottie-test-sandbox", "Music"]
        #expect(DottieNamedPlaceFinder.closestFolderName(to: "bowl and shit", among: realNames) == "bull and shit")
        #expect(DottieNamedPlaceFinder.closestFolderName(to: "dottie test sandbox", among: realNames) == "Dottie-test-sandbox")
        #expect(DottieNamedPlaceFinder.closestFolderName(to: "documents", among: realNames) == "Documents")
    }

    @Test func farOffOrTiedNamesAreNotGuessed() {
        #expect(DottieNamedPlaceFinder.closestFolderName(to: "taxes", among: ["Music", "Movies"]) == nil)
        #expect(DottieNamedPlaceFinder.closestFolderName(to: "cat", among: ["cab", "car"]) == nil)
        #expect(DottieNamedPlaceFinder.closestFolderName(to: "ab", among: ["ab"]) == nil)
    }

    @Test func editDistanceCountsChangedLetters() {
        #expect(DottieNamedPlaceFinder.editDistance("bowlandshit", "bullandshit") == 2)
        #expect(DottieNamedPlaceFinder.editDistance("", "abc") == 3)
        #expect(DottieNamedPlaceFinder.editDistance("same", "same") == 0)
    }
}
