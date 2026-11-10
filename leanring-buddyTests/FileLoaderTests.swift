//
//  FileLoaderTests.swift
//  leanring-buddyTests
//
//  Unit tests for DottieFileLoader: a saved list loads, a missing file is
//  simply "nothing saved yet", and a file that can't be understood is
//  kept as a copy instead of being lost to the next save.
//

import Foundation
import Testing
@testable import Dottie

struct FileLoaderTests {

    private struct SavedNote: Codable, Equatable {
        let title: String
        let writtenAt: Date
    }

    /// A fresh, empty folder for one test.
    private func makeTemporaryFolder() throws -> URL {
        let temporaryFolderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DottieFileLoaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryFolderURL, withIntermediateDirectories: true)
        return temporaryFolderURL
    }

    @Test func savedListLoads() throws {
        let temporaryFolderURL = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: temporaryFolderURL) }
        let fileURL = temporaryFolderURL.appendingPathComponent("names.json")
        try Data(#"["Scout","Coder"]"#.utf8).write(to: fileURL)

        let loadedNames = DottieFileLoader.load([String].self, from: fileURL)

        #expect(loadedNames == ["Scout", "Coder"])
        #expect(!FileManager.default.fileExists(atPath: DottieFileLoader.unreadableCopyURL(for: fileURL).path))
    }

    @Test func theGivenDecoderIsUsed() throws {
        let temporaryFolderURL = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: temporaryFolderURL) }
        let fileURL = temporaryFolderURL.appendingPathComponent("note.json")
        try Data(#"{"title":"Groceries","writtenAt":"2026-01-15T14:00:00Z"}"#.utf8).write(to: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let loadedNote = DottieFileLoader.load(SavedNote.self, from: fileURL, decoder: decoder)

        #expect(loadedNote == SavedNote(title: "Groceries", writtenAt: Date(timeIntervalSince1970: 1_768_485_600)))
    }

    @Test func missingFileIsNothingSavedAndLeavesNoCopy() throws {
        let temporaryFolderURL = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: temporaryFolderURL) }
        let fileURL = temporaryFolderURL.appendingPathComponent("names.json")

        let loadedNames = DottieFileLoader.load([String].self, from: fileURL)

        #expect(loadedNames == nil)
        #expect(!FileManager.default.fileExists(atPath: DottieFileLoader.unreadableCopyURL(for: fileURL).path))
    }

    @Test func fileThatCannotBeUnderstoodIsKeptAsACopy() throws {
        let temporaryFolderURL = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: temporaryFolderURL) }
        let fileURL = temporaryFolderURL.appendingPathComponent("names.json")
        let brokenData = Data(#"["Scout","Cod"#.utf8)
        try brokenData.write(to: fileURL)

        let loadedNames = DottieFileLoader.load([String].self, from: fileURL)

        #expect(loadedNames == nil)
        let unreadableCopyURL = DottieFileLoader.unreadableCopyURL(for: fileURL)
        #expect(try Data(contentsOf: unreadableCopyURL) == brokenData)
        // The original stays where it was; only the next save replaces it.
        #expect(try Data(contentsOf: fileURL) == brokenData)
    }

    @Test func fileOfAnotherShapeIsKeptAsACopyToo() throws {
        let temporaryFolderURL = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: temporaryFolderURL) }
        let fileURL = temporaryFolderURL.appendingPathComponent("names.json")
        let otherShapeData = Data(#"{"names":["Scout"]}"#.utf8)
        try otherShapeData.write(to: fileURL)

        let loadedNames = DottieFileLoader.load([String].self, from: fileURL)

        #expect(loadedNames == nil)
        #expect(try Data(contentsOf: DottieFileLoader.unreadableCopyURL(for: fileURL)) == otherShapeData)
    }

    @Test func copyIsNamedAfterTheFileItCameFrom() {
        let routinesFileURL = URL(fileURLWithPath: "/tmp/Dottie/Dots/routines.json")
        let fileWithoutExtensionURL = URL(fileURLWithPath: "/tmp/Dottie/roster")

        #expect(DottieFileLoader.unreadableCopyURL(for: routinesFileURL).path == "/tmp/Dottie/Dots/routines.unreadable.json")
        #expect(DottieFileLoader.unreadableCopyURL(for: fileWithoutExtensionURL).path == "/tmp/Dottie/roster.unreadable")
    }
}
