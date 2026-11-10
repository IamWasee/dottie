//
//  FileSaverTests.swift
//  leanring-buddyTests
//
//  Unit tests for DottieFileSaver: a save lands on disk whole, replaces
//  what was there, and a save that can't happen says so instead of
//  passing silently.
//

import Foundation
import Testing
@testable import Dottie

struct FileSaverTests {

    /// A fresh, empty folder for one test.
    private func makeTemporaryFolder() throws -> URL {
        let temporaryFolderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DottieFileSaverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryFolderURL, withIntermediateDirectories: true)
        return temporaryFolderURL
    }

    @Test func savedDataCanBeReadBack() throws {
        let temporaryFolderURL = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: temporaryFolderURL) }
        let fileURL = temporaryFolderURL.appendingPathComponent("list.json")
        let originalData = Data("[1,2,3]".utf8)

        let didSave = DottieFileSaver.save(originalData, to: fileURL)

        #expect(didSave)
        #expect(try Data(contentsOf: fileURL) == originalData)
    }

    @Test func savedTextCanBeReadBackIncludingNonEnglishLetters() throws {
        let temporaryFolderURL = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: temporaryFolderURL) }
        let fileURL = temporaryFolderURL.appendingPathComponent("notes.md")

        let didSave = DottieFileSaver.save(text: "# Café ☕️\nπ ≈ 3.14\n", to: fileURL)

        #expect(didSave)
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "# Café ☕️\nπ ≈ 3.14\n")
    }

    @Test func savingAgainReplacesTheOldContents() throws {
        let temporaryFolderURL = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: temporaryFolderURL) }
        let fileURL = temporaryFolderURL.appendingPathComponent("settings.json")

        DottieFileSaver.save(text: "a much longer first version of the file", to: fileURL)
        DottieFileSaver.save(text: "short", to: fileURL)

        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "short")
    }

    @Test func savingIntoAFolderThatDoesNotExistReportsFailure() throws {
        let temporaryFolderURL = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: temporaryFolderURL) }
        let fileURL = temporaryFolderURL
            .appendingPathComponent("no-such-folder", isDirectory: true)
            .appendingPathComponent("list.json")

        let didSave = DottieFileSaver.save(Data("[]".utf8), to: fileURL)

        #expect(!didSave)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }
}
