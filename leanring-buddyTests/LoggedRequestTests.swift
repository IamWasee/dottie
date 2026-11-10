//
//  LoggedRequestTests.swift
//  leanring-buddyTests
//
//  Unit tests for DottieLoggedRequest: an answer comes back whole, a
//  request that can't be answered gives nil instead of throwing, and a
//  cancelled request is told apart from a real failure. The tests read
//  files on this Mac through file addresses, so nothing reaches the
//  internet.
//

import Foundation
import Testing
@testable import Dottie

struct LoggedRequestTests {

    /// A fresh, empty folder for one test.
    private func makeTemporaryFolder() throws -> URL {
        let temporaryFolderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DottieLoggedRequestTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryFolderURL, withIntermediateDirectories: true)
        return temporaryFolderURL
    }

    @Test func sendReturnsTheAnswer() async throws {
        let temporaryFolderURL = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: temporaryFolderURL) }
        let fileURL = temporaryFolderURL.appendingPathComponent("answer.txt")
        let expectedData = Data("hello from the server".utf8)
        try expectedData.write(to: fileURL)

        let answer = await DottieLoggedRequest.send(URLRequest(url: fileURL))

        #expect(answer?.0 == expectedData)
    }

    @Test func fetchReturnsTheAnswer() async throws {
        let temporaryFolderURL = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: temporaryFolderURL) }
        let fileURL = temporaryFolderURL.appendingPathComponent("picture.bin")
        let expectedData = Data([1, 2, 3, 4])
        try expectedData.write(to: fileURL)

        let answer = await DottieLoggedRequest.fetch(from: fileURL)

        #expect(answer?.0 == expectedData)
    }

    @Test func aRequestThatFailsGivesNil() async throws {
        let temporaryFolderURL = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: temporaryFolderURL) }
        let missingFileURL = temporaryFolderURL.appendingPathComponent("not-there.txt")

        let answer = await DottieLoggedRequest.send(URLRequest(url: missingFileURL))

        #expect(answer == nil)
    }

    @Test func cancelledRequestsAreToldApartFromFailures() {
        #expect(DottieLoggedRequest.isCancellation(CancellationError()))
        #expect(DottieLoggedRequest.isCancellation(URLError(.cancelled)))
        #expect(!DottieLoggedRequest.isCancellation(URLError(.notConnectedToInternet)))
        #expect(!DottieLoggedRequest.isCancellation(URLError(.timedOut)))
        #expect(!DottieLoggedRequest.isCancellation(CocoaError(.fileNoSuchFile)))
    }
}
