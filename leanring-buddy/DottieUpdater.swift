//
//  DottieUpdater.swift
//  leanring-buddy
//
//  Updates Dottie from inside the app (Settings → Updates), so there's no
//  deleting and dragging in a new copy. It reads the newest GitHub release,
//  downloads Dottie.dmg, checks it against the release's SHA-256 file and
//  its code signature, swaps the app in place and reopens it.
//
//  Permissions survive an update only when every build is signed with the
//  same certificate: macOS remembers what you allowed by the app's signing
//  identity. Release builds signed with the project's own certificate keep
//  them; an ad-hoc build ("-") has a new identity every time.
//

import AppKit
import Combine
import CryptoKit
import Foundation
import Security
import UserNotifications

@MainActor
final class DottieUpdater: ObservableObject {
    static let shared = DottieUpdater()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String)
        case downloading(version: String)
        case installing(version: String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastCheckedAt: Date?
    /// Release notes of the available update, shown under the button.
    @Published private(set) var availableNotes: String = ""

    static let autoCheckDefaultsKey = "dottieChecksForUpdates"
    private static let checkIntervalSeconds: TimeInterval = 6 * 60 * 60

    private var availableRelease: Release?
    private var periodicCheckTask: Task<Void, Never>?

    struct Release {
        let version: String
        let dmgURL: URL
        let checksumURL: URL?
        let notes: String
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// owner/repo of the GitHub project releases come from. The release
    /// workflow writes it into Info.plist; the original project otherwise.
    private static var repository: String {
        let fromInfoPlist = (Bundle.main.infoDictionary?["DottieUpdateRepository"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return fromInfoPlist.contains("/") ? fromInfoPlist : "IamWasee/dottie"
    }

    // MARK: - Checking

    /// Checks now and then every few hours, unless turned off in Settings.
    func startPeriodicChecks() {
        UserDefaults.standard.register(defaults: [Self.autoCheckDefaultsKey: true])
        periodicCheckTask?.cancel()
        periodicCheckTask = Task { [weak self] in
            // Let the app finish starting up first.
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            while !Task.isCancelled {
                if UserDefaults.standard.bool(forKey: Self.autoCheckDefaultsKey) {
                    await self?.checkForUpdates()
                }
                try? await Task.sleep(nanoseconds: UInt64(Self.checkIntervalSeconds * 1_000_000_000))
            }
        }
    }

    func checkForUpdates() async {
        switch state {
        case .checking, .downloading, .installing: return
        default: break
        }
        state = .checking
        do {
            let release = try await Self.fetchLatestRelease()
            lastCheckedAt = Date()
            if Self.isVersion(release.version, newerThan: Self.currentVersion) {
                availableRelease = release
                availableNotes = release.notes
                state = .available(version: release.version)
                Self.notifyOnce(about: release.version)
            } else {
                availableRelease = nil
                availableNotes = ""
                state = .upToDate
            }
        } catch {
            state = .failed("Couldn't check for updates (\(error.localizedDescription)).")
        }
    }

    private static func fetchLatestRelease() async throws -> Release {
        do {
            return try await fetchLatestReleaseFromAPI()
        } catch {
            // GitHub's API allows only 60 requests an hour per network
            // without sign-in and answers 403 after that, which also counts
            // anything else on the same Wi-Fi. The release page and its
            // downloads have no such limit, so read the newest version from
            // where /releases/latest redirects instead.
            if let releaseFromPage = try? await fetchLatestReleaseFromReleasePage() {
                return releaseFromPage
            }
            throw error
        }
    }

    private static func fetchLatestReleaseFromAPI() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Dottie/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard statusCode == 200,
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = payload["tag_name"] as? String else {
            throw updateError("GitHub didn't answer, status \(statusCode)")
        }
        let assets = payload["assets"] as? [[String: Any]] ?? []
        func assetURL(named name: String) -> URL? {
            assets.first { ($0["name"] as? String) == name }
                .flatMap { $0["browser_download_url"] as? String }
                .flatMap(URL.init(string:))
        }
        guard let dmgURL = assetURL(named: "Dottie.dmg") else {
            throw updateError("the newest release has no Dottie.dmg yet")
        }
        let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        return Release(
            version: version,
            dmgURL: dmgURL,
            checksumURL: assetURL(named: "Dottie.dmg.sha256"),
            notes: (payload["body"] as? String) ?? ""
        )
    }

    /// github.com/<repository>/releases/latest redirects to
    /// /releases/tag/<tag>, and each asset is at /releases/download/<tag>/<name>.
    /// The page carries no release notes, so those stay empty.
    private static func fetchLatestReleaseFromReleasePage() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://github.com/\(repository)/releases/latest")!)
        request.httpMethod = "HEAD"
        request.setValue("Dottie/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let finalURL = (response as? HTTPURLResponse)?.url,
              finalURL.pathComponents.dropLast().last == "tag" else {
            throw updateError("GitHub didn't answer")
        }
        let tagName = finalURL.lastPathComponent
        let downloadFolderURL = URL(string: "https://github.com/\(repository)/releases/download/")!
            .appendingPathComponent(tagName, isDirectory: true)
        let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        return Release(
            version: version,
            dmgURL: downloadFolderURL.appendingPathComponent("Dottie.dmg"),
            checksumURL: downloadFolderURL.appendingPathComponent("Dottie.dmg.sha256"),
            notes: ""
        )
    }

    /// Compares dotted version numbers: 1.0.16 is newer than 1.0.9.
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let candidateParts = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let currentParts = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(candidateParts.count, currentParts.count) {
            let candidatePart = index < candidateParts.count ? candidateParts[index] : 0
            let currentPart = index < currentParts.count ? currentParts[index] : 0
            if candidatePart != currentPart { return candidatePart > currentPart }
        }
        return false
    }

    /// One notification per new version, so the user hears about it
    /// without opening Settings.
    private static func notifyOnce(about version: String) {
        let notifiedKey = "dottieNotifiedUpdateVersion"
        guard UserDefaults.standard.string(forKey: notifiedKey) != version else { return }
        UserDefaults.standard.set(version, forKey: notifiedKey)
        let content = UNMutableNotificationContent()
        content.title = "Dottie \(version) is out"
        content.body = "Update in Home → Settings → Updates. It takes a few seconds."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "dottie-update-\(version)", content: content, trigger: nil)
        )
    }

    // MARK: - Installing

    func installAvailableUpdate() {
        guard let release = availableRelease else { return }
        Task { await install(release) }
    }

    private func install(_ release: Release) async {
        let installedAppURL = Bundle.main.bundleURL
        let applicationFolder = installedAppURL.deletingLastPathComponent()
        guard installedAppURL.pathExtension == "app",
              FileManager.default.isWritableFile(atPath: applicationFolder.path) else {
            state = .failed("Dottie can't replace itself where it is (\(applicationFolder.path)). Move Dottie into Applications, then try again.")
            return
        }

        state = .downloading(version: release.version)
        let workFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("DottieUpdate-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
            let dmgFile = try await Self.download(release.dmgURL, to: workFolder.appendingPathComponent("Dottie.dmg"))
            if let checksumURL = release.checksumURL {
                try await Self.verifyChecksum(of: dmgFile, against: checksumURL)
            }

            state = .installing(version: release.version)
            let newAppURL = try await Self.copyApp(outOf: dmgFile, into: workFolder)
            try Self.verifySignature(of: newAppURL, replacing: installedAppURL)
            try Self.launchSwapScript(newAppURL: newAppURL, installedAppURL: installedAppURL, workFolder: workFolder)
        } catch {
            try? FileManager.default.removeItem(at: workFolder)
            state = .failed("The update didn't install: \(error.localizedDescription)")
            return
        }
        // The script waits for Dottie to quit, swaps the app and reopens it.
        NSApp.terminate(nil)
    }

    private static func download(_ url: URL, to destination: URL) async throws -> URL {
        var request = URLRequest(url: url)
        request.setValue("Dottie/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 300
        let (temporaryFile, response) = try await URLSession.shared.download(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw updateError("the download failed")
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporaryFile, to: destination)
        return destination
    }

    private static func verifyChecksum(of file: URL, against checksumURL: URL) async throws {
        var request = URLRequest(url: checksumURL)
        request.setValue("Dottie/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        let expected = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init)?.lowercased() ?? ""
        let fileData = try Data(contentsOf: file, options: .mappedIfSafe)
        let actual = SHA256.hash(data: fileData).map { String(format: "%02x", $0) }.joined()
        guard !expected.isEmpty, expected == actual else {
            throw updateError("the download doesn't match the release's checksum")
        }
    }

    /// Mounts the DMG, copies Dottie.app out and unmounts it.
    private static func copyApp(outOf dmgFile: URL, into workFolder: URL) async throws -> URL {
        let mountPoint = workFolder.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        guard await run("/usr/bin/hdiutil", ["attach", dmgFile.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mountPoint.path]) == 0 else {
            throw updateError("couldn't open the downloaded DMG")
        }
        defer { Task { await run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"]) } }
        let mountedApp = mountPoint.appendingPathComponent("Dottie.app")
        let stagedApp = workFolder.appendingPathComponent("Dottie.app")
        guard FileManager.default.fileExists(atPath: mountedApp.path),
              await run("/usr/bin/ditto", [mountedApp.path, stagedApp.path]) == 0 else {
            throw updateError("the DMG has no Dottie.app")
        }
        return stagedApp
    }

    /// The new app must be validly signed, be Dottie, and (when this copy is
    /// signed with a real certificate) be signed by the same certificate.
    private static func verifySignature(of newAppURL: URL, replacing installedAppURL: URL) throws {
        var newStaticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(newAppURL as CFURL, [], &newStaticCode) == errSecSuccess,
              let newStaticCode else {
            throw updateError("couldn't read the new app's signature")
        }
        let checkFlags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate))
        guard SecStaticCodeCheckValidity(newStaticCode, checkFlags, nil) == errSecSuccess else {
            throw updateError("the new app's signature isn't valid")
        }
        guard Bundle(url: newAppURL)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw updateError("the download isn't Dottie")
        }

        var installedStaticCode: SecStaticCode?
        var installedRequirement: SecRequirement?
        var requirementText: CFString?
        guard SecStaticCodeCreateWithPath(installedAppURL as CFURL, [], &installedStaticCode) == errSecSuccess,
              let installedStaticCode,
              SecCodeCopyDesignatedRequirement(installedStaticCode, [], &installedRequirement) == errSecSuccess,
              let installedRequirement,
              SecRequirementCopyString(installedRequirement, [], &requirementText) == errSecSuccess else {
            return
        }
        // An ad-hoc copy's requirement is its own hash, which no other build
        // can meet; only certificate-signed copies pin the next update.
        guard (requirementText as String?)?.contains("certificate") == true else { return }
        guard SecStaticCodeCheckValidity(newStaticCode, checkFlags, installedRequirement) == errSecSuccess else {
            throw updateError("the new app isn't signed by the same certificate as this one")
        }
    }

    /// Waits for this Dottie to quit, puts the new app where the old one
    /// was (keeping the old one until the new one is in place) and opens it.
    private static func launchSwapScript(newAppURL: URL, installedAppURL: URL, workFolder: URL) throws {
        let script = """
        #!/bin/bash
        while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done
        new="$2"; target="$3"; work="$4"; old="$work/Dottie-old.app"
        if /bin/mv "$target" "$old"; then
            if ! /bin/mv "$new" "$target"; then /bin/mv "$old" "$target"; fi
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$target" 2>/dev/null
        /usr/bin/open "$target"
        /bin/rm -rf "$work"
        """
        let scriptURL = workFolder.appendingPathComponent("swap.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        // nohup and & detach it, so it outlives Dottie quitting.
        process.arguments = ["-c", "/usr/bin/nohup /bin/bash \"$0\" \"$1\" \"$2\" \"$3\" \"$4\" >/dev/null 2>&1 &",
                             scriptURL.path, String(ProcessInfo.processInfo.processIdentifier),
                             newAppURL.path, installedAppURL.path, workFolder.path]
        try process.run()
        process.waitUntilExit()
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: -1)
            }
        }
    }

    private static func updateError(_ message: String) -> NSError {
        NSError(domain: "DottieUpdater", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - Signing identity

    /// True when this copy is signed with a certificate (not ad-hoc), so
    /// permissions carry over to updates signed the same way.
    static var keepsPermissionsAcrossUpdates: Bool {
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        var requirementText: CFString?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
              let requirement,
              SecRequirementCopyString(requirement, [], &requirementText) == errSecSuccess else { return false }
        return (requirementText as String?)?.contains("certificate") == true
    }
}
