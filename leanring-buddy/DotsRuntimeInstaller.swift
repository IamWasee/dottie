//
//  DotsRuntimeInstaller.swift
//  leanring-buddy
//
//  Gets Dots ready with no Terminal. Shipped Clicky puts its agent CLI
//  (Codex) inside the app; Dots run on Gemini CLI, which needs Node.js, so
//  Dottie downloads pinned copies of both the first time they're needed:
//
//    ~/Library/Application Support/Dottie/Runtime/
//      node-v<version>-darwin-<arch>/     official Node.js build (nodejs.org)
//      gemini-cli-<version>/package/      @google/gemini-cli from npm
//      bin/gemini                         launcher: Dottie's node + gemini.js
//
//  Both downloads are checked against hashes pinned here before anything
//  is unpacked. Gemini CLI's npm package is a self-contained bundle (its
//  only dependencies are optional terminal helpers headless mode doesn't
//  use), so no npm install runs. About 70 MB, once.
//
//  To update, change the versions and hashes below:
//    Node:       https://nodejs.org/dist/v<version>/SHASUMS256.txt (darwin-*.tar.gz)
//    Gemini CLI: https://registry.npmjs.org/@google/gemini-cli/<version> (dist.integrity)
//

import CryptoKit
import Foundation

/// Static members aren't actor-isolated, so the paths and versions can be
/// read from anywhere; only the running install is guarded by the actor.
actor DotsRuntimeInstaller {
    static let shared = DotsRuntimeInstaller()

    static let nodeVersion = "24.22.0"
    static let geminiCLIVersion = "0.64.0"
    private static let nodeTarballSHA256ByArchitecture = [
        "arm64": "6a9724d9b50a5f22b4816cded441b5a8d9ddae546191a5e5b7efa5a5e2ee26d5",
        "x64": "495e3f273c645f3c4677d438304cdfc701729ea5dec5728f5c8e76a2dece4b91"
    ]
    private static let geminiCLITarballIntegrity =
        "sha512-FHrZ1NPf9QszyVMaa/BP3SsPy40ogBLnbZNWkv/PMi1Uz2zoDNMLGiBzBGmx4Bl7iLRq01K9PY/5kmloXFTpsA=="

    enum InstallError: LocalizedError {
        case downloadFailed(String)
        case checksumMismatch(String)
        case unpackFailed(String)

        var errorDescription: String? {
            switch self {
            case .downloadFailed(let detail):
                return "Couldn't download what Dots need (\(detail)). Check your internet connection and try again."
            case .checksumMismatch(let fileName):
                return "\(fileName) didn't match its checksum, so Dottie didn't use it. Try again later."
            case .unpackFailed(let detail):
                return "Couldn't unpack what Dots need: \(detail)"
            }
        }
    }

    private var runningInstallTask: Task<Void, Error>?

    // MARK: - Where things live

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x64"
        #endif
    }

    static var runtimeFolderURL: URL {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return applicationSupportURL
            .appendingPathComponent("Dottie", isDirectory: true)
            .appendingPathComponent("Runtime", isDirectory: true)
    }

    private static var nodeFolderName: String {
        "node-v\(nodeVersion)-darwin-\(architecture)"
    }

    /// Dottie's own node, npm and npx. Added to the Dots' PATH.
    static var nodeBinFolderURL: URL {
        runtimeFolderURL.appendingPathComponent(nodeFolderName, isDirectory: true).appendingPathComponent("bin", isDirectory: true)
    }

    static var geminiLauncherURL: URL {
        runtimeFolderURL.appendingPathComponent("bin/gemini", isDirectory: false)
    }

    private static var installedMarkerURL: URL {
        runtimeFolderURL.appendingPathComponent("installed.txt", isDirectory: false)
    }

    private static var expectedMarkerText: String {
        "node \(nodeVersion) \(architecture)\ngemini-cli \(geminiCLIVersion)\n"
    }

    /// True once this version of the runtime is fully unpacked.
    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: geminiLauncherURL.path)
            && (try? String(contentsOf: installedMarkerURL, encoding: .utf8)) == expectedMarkerText
    }

    // MARK: - Installing

    /// Downloads and unpacks the runtime unless it's already there. Calls
    /// made while an install is running wait for that install.
    func installIfNeeded() async throws {
        if Self.isInstalled { return }
        if let runningInstallTask {
            return try await runningInstallTask.value
        }
        let installTask = Task.detached(priority: .utility) {
            try await Self.install()
        }
        runningInstallTask = installTask
        defer { runningInstallTask = nil }
        try await installTask.value
    }

    private static func install() async throws {
        let fileManager = FileManager.default
        let runtimeFolderURL = Self.runtimeFolderURL
        // Start clean: an older version or a half-finished install.
        try? fileManager.removeItem(at: runtimeFolderURL)
        try fileManager.createDirectory(at: runtimeFolderURL, withIntermediateDirectories: true)

        let downloadFolderURL = fileManager.temporaryDirectory.appendingPathComponent("dottie-runtime-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: downloadFolderURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: downloadFolderURL) }

        // Node.js
        let nodeTarballName = "\(nodeFolderName).tar.gz"
        let nodeTarballURL = try await download(
            from: URL(string: "https://nodejs.org/dist/v\(nodeVersion)/\(nodeTarballName)")!,
            to: downloadFolderURL.appendingPathComponent(nodeTarballName)
        )
        let nodeTarballData = try Data(contentsOf: nodeTarballURL, options: .mappedIfSafe)
        let nodeTarballSHA256 = SHA256.hash(data: nodeTarballData).map { String(format: "%02x", $0) }.joined()
        guard nodeTarballSHA256 == nodeTarballSHA256ByArchitecture[architecture] else {
            throw InstallError.checksumMismatch(nodeTarballName)
        }
        try unpack(tarballURL: nodeTarballURL, into: runtimeFolderURL)

        // Gemini CLI
        let geminiTarballName = "gemini-cli-\(geminiCLIVersion).tgz"
        let geminiTarballURL = try await download(
            from: URL(string: "https://registry.npmjs.org/@google/gemini-cli/-/\(geminiTarballName)")!,
            to: downloadFolderURL.appendingPathComponent(geminiTarballName)
        )
        let geminiTarballData = try Data(contentsOf: geminiTarballURL, options: .mappedIfSafe)
        let geminiTarballIntegrity = "sha512-" + Data(SHA512.hash(data: geminiTarballData)).base64EncodedString()
        guard geminiTarballIntegrity == geminiCLITarballIntegrity else {
            throw InstallError.checksumMismatch(geminiTarballName)
        }
        let geminiFolderURL = runtimeFolderURL.appendingPathComponent("gemini-cli-\(geminiCLIVersion)", isDirectory: true)
        try fileManager.createDirectory(at: geminiFolderURL, withIntermediateDirectories: true)
        try unpack(tarballURL: geminiTarballURL, into: geminiFolderURL)

        let nodeExecutableURL = nodeBinFolderURL.appendingPathComponent("node")
        let geminiScriptURL = geminiFolderURL.appendingPathComponent("package/bundle/gemini.js")
        guard fileManager.isExecutableFile(atPath: nodeExecutableURL.path),
              fileManager.fileExists(atPath: geminiScriptURL.path) else {
            throw InstallError.unpackFailed("the downloads didn't contain node and gemini.js")
        }

        // The launcher Dots run as `gemini`.
        let launcherScript = """
        #!/bin/sh
        # Written by Dottie: runs Gemini CLI on Dottie's own copy of Node.js.
        exec "\(nodeExecutableURL.path)" "\(geminiScriptURL.path)" "$@"

        """
        try fileManager.createDirectory(at: geminiLauncherURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try launcherScript.write(to: geminiLauncherURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: geminiLauncherURL.path)

        try expectedMarkerText.write(to: installedMarkerURL, atomically: true, encoding: .utf8)
        print("✅ Dots runtime ready: Node \(nodeVersion), Gemini CLI \(geminiCLIVersion)")
    }

    private static func download(from remoteURL: URL, to destinationURL: URL) async throws -> URL {
        let downloadResult: (URL, URLResponse)
        do {
            downloadResult = try await URLSession.shared.download(from: remoteURL)
        } catch {
            throw InstallError.downloadFailed(error.localizedDescription)
        }
        let (downloadedFileURL, response) = downloadResult
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw InstallError.downloadFailed("\(remoteURL.lastPathComponent) answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.moveItem(at: downloadedFileURL, to: destinationURL)
        return destinationURL
    }

    private static func unpack(tarballURL: URL, into folderURL: URL) throws {
        let tarProcess = Process()
        tarProcess.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tarProcess.arguments = ["-xzf", tarballURL.path, "-C", folderURL.path]
        let errorPipe = Pipe()
        tarProcess.standardError = errorPipe
        tarProcess.standardOutput = FileHandle.nullDevice
        try tarProcess.run()
        tarProcess.waitUntilExit()
        guard tarProcess.terminationStatus == 0 else {
            let errorOutput = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw InstallError.unpackFailed(errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
