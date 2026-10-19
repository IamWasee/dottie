//
//  DottieMausBotAppInstaller.swift
//  leanring-buddy
//
//  Puts the OpenMausBot Mac app ("the MausBot app") on this Mac, so helpers
//  run on the user's Claude plan without anyone setting MausBot up by hand.
//  DottieMausBot runs it in the background on launch and from Set up; the
//  `openmausbot` npm package is only the fallback when this fails.
//
//  The app is signed and notarized by its makers. Dottie:
//    1. downloads the release disk image for this Mac's chip from GitHub
//       (OpenMausBot.dmg for Apple silicon, OpenMausBot-intel.dmg for Intel),
//    2. mounts it with hdiutil (no Finder window),
//    3. copies OpenMausBot.app out with `ditto`, which keeps the code
//       signature intact, into a hidden folder next to its final place,
//    4. checks the copy is validly signed with a Developer ID as
//       com.openmausbot.app, then moves it into /Applications (or
//       ~/Applications when /Applications can't be written to),
//    5. unmounts the image and deletes it.
//  An OpenMausBot that's already there is never replaced or quit.
//
//  Quarantine: Dottie isn't sandboxed and doesn't set LSFileQuarantineEnabled,
//  so what URLSession downloads isn't flagged, and nothing here adds or
//  strips the flag. The app is notarized either way.
//
//  The app and `openmausbot serve` keep their data in the same folder
//  (~/.openmausbot: bots, chats, settings), so the helper bots Dottie made
//  with its npm copy are in the app too. See DottieMausBot.switchToDesktopApp.
//

import Foundation
import Security

enum DottieMausBotAppInstaller {
    static let appleSiliconDownloadURL = URL(string: "https://github.com/milind-soni/OpenMausBot/releases/latest/download/OpenMausBot.dmg")!
    static let intelDownloadURL = URL(string: "https://github.com/milind-soni/OpenMausBot/releases/latest/download/OpenMausBot-intel.dmg")!
    static let appBundleName = "OpenMausBot.app"

    /// A Developer ID app signed as com.openmausbot.app (what Gatekeeper
    /// itself asks of a notarized download).
    private static let signatureRequirementText =
        "anchor apple generic and identifier \"\(DottieMausBotLocator.desktopAppBundleIdentifier)\""
        + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
        + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"

    /// Where an install is, for the status line in Settings → Helpers.
    enum Stage: Sendable, Equatable {
        case downloading(percentDone: Int?)
        case installing

        var statusText: String {
            switch self {
            case .downloading(let percentDone):
                guard let percentDone else { return "Installing the MausBot app (downloading)…" }
                return "Installing the MausBot app (downloading, \(percentDone)%)…"
            case .installing:
                return "Installing the MausBot app…"
            }
        }
    }

    struct InstallError: LocalizedError {
        let message: String

        init(_ message: String) {
            self.message = message
        }

        var errorDescription: String? { message }
    }

    /// True on Apple silicon, also when Dottie itself runs under Rosetta.
    static var isAppleSilicon: Bool {
        var isARM64: Int32 = 0
        var valueSize = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &isARM64, &valueSize, nil, 0) == 0 {
            return isARM64 == 1
        }
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    static var downloadURLForThisMac: URL {
        isAppleSilicon ? appleSiliconDownloadURL : intelDownloadURL
    }

    // MARK: - Installing

    /// Downloads and installs the app; returns where it is now. `onStage`
    /// runs on the main actor. When an OpenMausBot.app is already in the
    /// folder it would go to, that one is returned untouched.
    static func install(onStage: @escaping @MainActor @Sendable (Stage) -> Void) async throws -> URL {
        let reportStage: @Sendable (Stage) -> Void = { stage in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    onStage(stage)
                }
            }
        }

        let workFolderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DottieMausBotApp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workFolderURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workFolderURL) }

        reportStage(.downloading(percentDone: nil))
        let diskImageURL = workFolderURL.appendingPathComponent("OpenMausBot.dmg", isDirectory: false)
        try await download(downloadURLForThisMac, to: diskImageURL, reportStage: reportStage)

        reportStage(.installing)
        let mountPointURL = workFolderURL.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPointURL, withIntermediateDirectories: true)
        let attachResult = await runTool("/usr/bin/hdiutil", [
            "attach", diskImageURL.path,
            "-nobrowse", "-noverify", "-noautoopen", "-readonly",
            "-mountpoint", mountPointURL.path
        ], timeout: 5 * 60)
        guard attachResult.exitCode == 0 else {
            throw InstallError("couldn't open the downloaded disk image (\(attachResult.standardErrorTail))")
        }

        do {
            let installedAppURL = try await copyApp(fromMountedVolume: mountPointURL)
            await detach(mountPointURL)
            return installedAppURL
        } catch {
            await detach(mountPointURL)
            throw error
        }
    }

    private static func download(
        _ remoteURL: URL,
        to destinationURL: URL,
        reportStage: @escaping @Sendable (Stage) -> Void
    ) async throws {
        var request = URLRequest(url: remoteURL)
        let dottieVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        request.setValue("Dottie/\(dottieVersion)", forHTTPHeaderField: "User-Agent")

        let downloadDelegate = DottieMausBotAppDownloadDelegate(destinationURL: destinationURL, reportStage: reportStage)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60
        // One session for this one download; invalidating it also lets go of the delegate.
        let downloadSession = URLSession(configuration: configuration, delegate: downloadDelegate, delegateQueue: nil)
        defer { downloadSession.finishTasksAndInvalidate() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            downloadDelegate.setContinuation(continuation)
            downloadSession.downloadTask(with: request).resume()
        }
    }

    /// Copies the app into the first Applications folder that takes it.
    private static func copyApp(fromMountedVolume mountPointURL: URL) async throws -> URL {
        guard let mountedAppURL = findApp(inMountedVolume: mountPointURL) else {
            throw InstallError("the disk image has no OpenMausBot app")
        }
        var lastError: Error = InstallError("neither /Applications nor ~/Applications can be written to")
        for applicationsFolderURL in candidateApplicationsFolders() {
            let installedAppURL = applicationsFolderURL.appendingPathComponent(appBundleName, isDirectory: true)
            // Never replace a copy that's already there: it may be running, or newer.
            if FileManager.default.fileExists(atPath: installedAppURL.path) {
                return installedAppURL
            }
            do {
                try await copyApp(at: mountedAppURL, to: installedAppURL)
                return installedAppURL
            } catch {
                lastError = error
                if FileManager.default.fileExists(atPath: installedAppURL.path) {
                    // Another copy landed there meanwhile; use that one.
                    return installedAppURL
                }
            }
        }
        throw lastError
    }

    /// `ditto` into a hidden folder beside the final place, check the
    /// signature of exactly what was copied, then move it in. The final
    /// place never holds a half-copied app.
    private static func copyApp(at mountedAppURL: URL, to installedAppURL: URL) async throws {
        let applicationsFolderURL = installedAppURL.deletingLastPathComponent()
        let stagingFolderURL = applicationsFolderURL
            .appendingPathComponent(".OpenMausBot-from-Dottie-\(UUID().uuidString)", isDirectory: true)
        let stagedAppURL = stagingFolderURL.appendingPathComponent(appBundleName, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stagingFolderURL) }

        let copyResult = await runTool("/usr/bin/ditto", [mountedAppURL.path, stagedAppURL.path], timeout: 15 * 60)
        guard copyResult.exitCode == 0 else {
            throw InstallError("couldn't copy the app into \(applicationsFolderURL.path) (\(copyResult.standardErrorTail))")
        }
        try verifySignature(of: stagedAppURL)
        try FileManager.default.moveItem(at: stagedAppURL, to: installedAppURL)
    }

    private static func findApp(inMountedVolume mountPointURL: URL) -> URL? {
        let expectedAppURL = mountPointURL.appendingPathComponent(appBundleName, isDirectory: true)
        if FileManager.default.fileExists(atPath: expectedAppURL.path) {
            return expectedAppURL
        }
        let volumeContents = (try? FileManager.default.contentsOfDirectory(at: mountPointURL, includingPropertiesForKeys: nil)) ?? []
        return volumeContents.first { candidateURL in
            candidateURL.pathExtension == "app"
                && Bundle(url: candidateURL)?.bundleIdentifier == DottieMausBotLocator.desktopAppBundleIdentifier
        }
    }

    /// /Applications when it can be written to, then ~/Applications (made
    /// if it's missing), which DottieMausBotLocator also looks in.
    private static func candidateApplicationsFolders() -> [URL] {
        var folderURLs: [URL] = []
        let systemApplicationsURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if FileManager.default.isWritableFile(atPath: systemApplicationsURL.path) {
            folderURLs.append(systemApplicationsURL)
        }
        let userApplicationsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        if (try? FileManager.default.createDirectory(at: userApplicationsURL, withIntermediateDirectories: true)) != nil,
           FileManager.default.isWritableFile(atPath: userApplicationsURL.path) {
            folderURLs.append(userApplicationsURL)
        }
        return folderURLs
    }

    /// The copy must be validly signed, nested code included, with a
    /// Developer ID as com.openmausbot.app.
    private static func verifySignature(of appURL: URL) throws {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            throw InstallError("couldn't read the app's signature")
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(signatureRequirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement else {
            throw InstallError("couldn't check the app's signature")
        }
        let checkFlags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate))
        let validityStatus = SecStaticCodeCheckValidity(staticCode, checkFlags, requirement)
        guard validityStatus == errSecSuccess else {
            throw InstallError("the app's signature didn't check out (error \(validityStatus))")
        }
    }

    private static func detach(_ mountPointURL: URL) async {
        let detachResult = await runTool("/usr/bin/hdiutil", ["detach", mountPointURL.path], timeout: 60)
        if detachResult.exitCode != 0 {
            _ = await runTool("/usr/bin/hdiutil", ["detach", mountPointURL.path, "-force"], timeout: 60)
        }
    }

    private static func runTool(_ executablePath: String, _ arguments: [String], timeout: TimeInterval) async -> DottieMausBotCommandResult {
        await DottieMausBotProcessRunner.run(
            executableURL: URL(fileURLWithPath: executablePath),
            arguments: arguments,
            environment: ProcessInfo.processInfo.environment,
            timeout: timeout
        )
    }
}

/// Saves one download where it's asked to and reports its progress. Called
/// on the session's own background queue.
private final class DottieMausBotAppDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destinationURL: URL
    private let reportStage: @Sendable (DottieMausBotAppInstaller.Stage) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var savingError: Error?
    private var lastReportedPercentDone: Int?

    init(destinationURL: URL, reportStage: @escaping @Sendable (DottieMausBotAppInstaller.Stage) -> Void) {
        self.destinationURL = destinationURL
        self.reportStage = reportStage
    }

    func setContinuation(_ newContinuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        continuation = newContinuation
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fractionDone = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let percentDone = min(100, max(0, Int(fractionDone * 100)))
        lock.lock()
        let isNewPercent = percentDone != lastReportedPercentDone
        lastReportedPercentDone = percentDone
        lock.unlock()
        if isNewPercent {
            reportStage(.downloading(percentDone: percentDone))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file at `location` is gone once this returns, so it moves now.
        var errorWhileSaving: Error?
        let statusCode = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        if statusCode != 200 {
            errorWhileSaving = DottieMausBotAppInstaller.InstallError("the download failed (HTTP \(statusCode))")
        } else {
            do {
                try? FileManager.default.removeItem(at: destinationURL)
                try FileManager.default.moveItem(at: location, to: destinationURL)
            } catch {
                errorWhileSaving = error
            }
        }
        lock.lock()
        savingError = errorWhileSaving
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let finishedContinuation = continuation
        continuation = nil
        let errorWhileSaving = savingError
        lock.unlock()
        if let error {
            finishedContinuation?.resume(throwing: DottieMausBotAppInstaller.InstallError("the download failed (\(error.localizedDescription))"))
        } else if let errorWhileSaving {
            finishedContinuation?.resume(throwing: errorWhileSaving)
        } else {
            finishedContinuation?.resume()
        }
    }
}
