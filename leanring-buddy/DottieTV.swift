//
//  DottieTV.swift
//  leanring-buddy
//
//  The ways Dottie reaches a TV, used by DottieSmartHome:
//
//  - Android TV, Google TV and Fire TV over ADB on Wi-Fi: Dottie sees the
//    TV's screen (screencap), presses remote buttons, types, opens apps and
//    links. scrcpy mirrors the TV into a window on the Mac, so the user (and
//    Dottie's screen jobs) can use it like any app. adb and scrcpy come from
//    Homebrew; Home → Smart Home installs them.
//  - Roku over its local remote API (ECP, port 8060): buttons, typing, apps.
//    It can't show its screen, so a capture card is Dottie's eyes for it.
//  - Any other TV: an HDMI capture card shows the TV's picture (it appears
//    to the Mac as a camera), and a CH9329 USB keyboard adapter (a few
//    dollars: USB serial on the Mac's side, a USB keyboard on the TV's side)
//    presses keys on it.
//

import AppKit
import AVFoundation
import CoreImage
import Foundation

enum DottieTV {
    // MARK: - Remote buttons

    /// Remote buttons by the names Dottie uses, with each backend's code.
    struct RemoteKey {
        let androidKeyCode: Int
        let rokuKey: String?
        /// USB keyboard usage for the CH9329 adapter, or a media key bit.
        let keyboardUsage: UInt8?
        let mediaKeyBit: UInt8?
    }

    static let remoteKeys: [String: RemoteKey] = [
        "up": RemoteKey(androidKeyCode: 19, rokuKey: "Up", keyboardUsage: 0x52, mediaKeyBit: nil),
        "down": RemoteKey(androidKeyCode: 20, rokuKey: "Down", keyboardUsage: 0x51, mediaKeyBit: nil),
        "left": RemoteKey(androidKeyCode: 21, rokuKey: "Left", keyboardUsage: 0x50, mediaKeyBit: nil),
        "right": RemoteKey(androidKeyCode: 22, rokuKey: "Right", keyboardUsage: 0x4F, mediaKeyBit: nil),
        "ok": RemoteKey(androidKeyCode: 23, rokuKey: "Select", keyboardUsage: 0x28, mediaKeyBit: nil),
        "back": RemoteKey(androidKeyCode: 4, rokuKey: "Back", keyboardUsage: 0x29, mediaKeyBit: nil),
        "home": RemoteKey(androidKeyCode: 3, rokuKey: "Home", keyboardUsage: nil, mediaKeyBit: nil),
        "menu": RemoteKey(androidKeyCode: 82, rokuKey: "Info", keyboardUsage: 0x65, mediaKeyBit: nil),
        "search": RemoteKey(androidKeyCode: 84, rokuKey: "Search", keyboardUsage: nil, mediaKeyBit: nil),
        "play_pause": RemoteKey(androidKeyCode: 85, rokuKey: "Play", keyboardUsage: nil, mediaKeyBit: 0x08),
        "next": RemoteKey(androidKeyCode: 87, rokuKey: "Fwd", keyboardUsage: nil, mediaKeyBit: 0x10),
        "previous": RemoteKey(androidKeyCode: 88, rokuKey: "Rev", keyboardUsage: nil, mediaKeyBit: 0x20),
        "fast_forward": RemoteKey(androidKeyCode: 90, rokuKey: "Fwd", keyboardUsage: nil, mediaKeyBit: nil),
        "rewind": RemoteKey(androidKeyCode: 89, rokuKey: "Rev", keyboardUsage: nil, mediaKeyBit: nil),
        "volume_up": RemoteKey(androidKeyCode: 24, rokuKey: "VolumeUp", keyboardUsage: nil, mediaKeyBit: 0x01),
        "volume_down": RemoteKey(androidKeyCode: 25, rokuKey: "VolumeDown", keyboardUsage: nil, mediaKeyBit: 0x02),
        "mute": RemoteKey(androidKeyCode: 164, rokuKey: "VolumeMute", keyboardUsage: nil, mediaKeyBit: 0x04),
        "power": RemoteKey(androidKeyCode: 26, rokuKey: "Power", keyboardUsage: nil, mediaKeyBit: nil),
        "sleep": RemoteKey(androidKeyCode: 223, rokuKey: "PowerOff", keyboardUsage: nil, mediaKeyBit: nil),
        "wake": RemoteKey(androidKeyCode: 224, rokuKey: "PowerOn", keyboardUsage: nil, mediaKeyBit: nil),
        "settings": RemoteKey(androidKeyCode: 176, rokuKey: nil, keyboardUsage: nil, mediaKeyBit: nil),
        "input": RemoteKey(androidKeyCode: 178, rokuKey: "InputHDMI1", keyboardUsage: nil, mediaKeyBit: nil),
        "channel_up": RemoteKey(androidKeyCode: 166, rokuKey: "ChannelUp", keyboardUsage: 0x4B, mediaKeyBit: nil),
        "channel_down": RemoteKey(androidKeyCode: 167, rokuKey: "ChannelDown", keyboardUsage: 0x4E, mediaKeyBit: nil),
        "delete": RemoteKey(androidKeyCode: 67, rokuKey: "Backspace", keyboardUsage: 0x2A, mediaKeyBit: nil)
    ]

    static var remoteKeyNames: [String] { remoteKeys.keys.sorted() }

    // MARK: - Tools on the Mac (adb, scrcpy, Homebrew)

    static func locateTool(_ name: String) -> String? {
        let homeFolder = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(homeFolder)/Library/Android/sdk/platform-tools/\(name)",
            "/opt/homebrew/Caskroom/android-platform-tools/latest/platform-tools/\(name)"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isADBInstalled: Bool { locateTool("adb") != nil }
    static var isScrcpyInstalled: Bool { locateTool("scrcpy") != nil }
    static var isHomebrewInstalled: Bool { locateTool("brew") != nil }

    /// Installs adb and scrcpy with Homebrew. Returns nil when done, or why not.
    static func installTVTools() async -> String? {
        guard let brewPath = locateTool("brew") else {
            return "Homebrew isn't installed. Get it from brew.sh, then try again."
        }
        var failures: [String] = []
        if !isADBInstalled {
            let result = await DottieMacActions.runProcess(brewPath, arguments: ["install", "--cask", "android-platform-tools"], timeout: 900)
            if result.exitCode != 0 { failures.append("adb: \(result.errorOutput.suffix(200))") }
        }
        if !isScrcpyInstalled {
            let result = await DottieMacActions.runProcess(brewPath, arguments: ["install", "scrcpy"], timeout: 900)
            if result.exitCode != 0 { failures.append("scrcpy: \(result.errorOutput.suffix(200))") }
        }
        return failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    // MARK: - ADB (Android TV, Google TV, Fire TV)

    @discardableResult
    static func adb(_ arguments: [String], timeout: TimeInterval = 15) async -> DottieMacActions.ProcessResult {
        guard let adbPath = locateTool("adb") else {
            return DottieMacActions.ProcessResult(exitCode: -1, output: "", errorOutput: "adb isn't installed", timedOut: false)
        }
        return await DottieMacActions.runProcess(adbPath, arguments: arguments, timeout: timeout)
    }

    /// Connects to a TV with network debugging on. The first time, the TV
    /// asks "Allow debugging?" on screen. Returns nil when connected.
    static func adbConnect(address: String) async -> String? {
        let fullAddress = address.contains(":") ? address : "\(address):5555"
        let result = await adb(["connect", fullAddress], timeout: 20)
        let output = (result.output + " " + result.errorOutput).lowercased()
        if output.contains("connected to") || output.contains("already connected") {
            // Unauthorized until the user says yes on the TV.
            let state = await adb(["-s", fullAddress, "get-state"], timeout: 8)
            if state.output.contains("device") { return nil }
            return "the TV is asking whether to allow debugging: pick Allow (and Always allow) with the TV remote, then connect again."
        }
        if output.contains("refused") {
            return "the TV refused. Turn on network or wireless debugging in the TV's developer options."
        }
        return result.output.isEmpty ? result.errorOutput : result.output
    }

    /// Android 11+ wireless debugging: pair once with the code the TV shows.
    static func adbPair(address: String, code: String) async -> String? {
        let result = await adb(["pair", address, code], timeout: 25)
        return result.output.lowercased().contains("successfully paired") ? nil : (result.output + " " + result.errorOutput)
    }

    static func adbIsConnected(serial: String) async -> Bool {
        await adb(["-s", serial, "get-state"], timeout: 6).output.contains("device")
    }

    static func adbPress(serial: String, keyName: String) async -> Bool {
        guard let key = remoteKeys[keyName] else { return false }
        return await adb(["-s", serial, "shell", "input", "keyevent", String(key.androidKeyCode)]).exitCode == 0
    }

    static func adbType(serial: String, text: String) async -> Bool {
        // The TV's shell splits on spaces; input text wants %s for a space.
        let escapedText = text
            .replacingOccurrences(of: "'", with: "'\\''")
            .replacingOccurrences(of: " ", with: "%s")
        return await adb(["-s", serial, "shell", "input", "text", "'\(escapedText)'"]).exitCode == 0
    }

    /// Well-known TV apps by name; anything else is found in the installed list.
    static let knownAndroidTVApps: [String: String] = [
        "youtube": "com.google.android.youtube.tv",
        "youtube kids": "com.google.android.youtube.tvkids",
        "youtube music": "com.google.android.youtube.tvmusic",
        "netflix": "com.netflix.ninja",
        "prime video": "com.amazon.amazonvideo.livingroom",
        "disney+": "com.disney.disneyplus",
        "disney plus": "com.disney.disneyplus",
        "spotify": "com.spotify.tv.android",
        "plex": "com.plexapp.android",
        "twitch": "tv.twitch.android.app",
        "max": "com.wbd.stream",
        "hulu": "com.hulu.livingroomplus",
        "apple tv": "com.apple.atve.androidtv.appletv",
        "kodi": "org.xbmc.kodi",
        "vlc": "org.videolan.vlc",
        "settings": "com.android.tv.settings",
        "play store": "com.android.vending",
        "google tv": "com.google.android.apps.tv.launcherx"
    ]

    static func adbOpenApp(serial: String, name: String) async -> String {
        let wantedName = name.lowercased().trimmingCharacters(in: .whitespaces)
        var packageName = knownAndroidTVApps[wantedName] ?? (wantedName.contains(".") ? wantedName : nil)
        if packageName == nil {
            let installed = await adb(["-s", serial, "shell", "pm", "list", "packages"], timeout: 15).output
                .split(separator: "\n").map { $0.replacingOccurrences(of: "package:", with: "") }
            let squashedName = wantedName.replacingOccurrences(of: " ", with: "")
            packageName = installed.first { $0.lowercased().contains(squashedName) }
        }
        guard let packageName else { return "couldn't find an app called \(name) on the TV." }
        var result = await adb(["-s", serial, "shell", "monkey", "-p", packageName, "-c", "android.intent.category.LEANBACK_LAUNCHER", "1"])
        if result.output.contains("No activities found") || result.exitCode != 0 {
            result = await adb(["-s", serial, "shell", "monkey", "-p", packageName, "-c", "android.intent.category.LAUNCHER", "1"])
        }
        return result.exitCode == 0 && !result.output.contains("No activities found")
            ? "opened \(name) on the TV."
            : "couldn't open \(name) on the TV."
    }

    static func adbOpenURL(serial: String, url: String) async -> Bool {
        let quotedURL = "'" + url.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return await adb(["-s", serial, "shell", "am", "start", "-a", "android.intent.action.VIEW", "-d", quotedURL]).exitCode == 0
    }

    /// What's on the TV right now, as a PNG.
    static func adbScreenshot(serial: String) async -> Data? {
        let remotePath = "/sdcard/dottie-tv-screen.png"
        guard await adb(["-s", serial, "shell", "screencap", "-p", remotePath], timeout: 15).exitCode == 0 else { return nil }
        let localURL = FileManager.default.temporaryDirectory.appendingPathComponent("dottie-tv-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: localURL) }
        guard await adb(["-s", serial, "pull", remotePath, localURL.path], timeout: 20).exitCode == 0 else { return nil }
        return try? Data(contentsOf: localURL)
    }

    /// Which app is in front and whether the screen is on.
    static func adbStatus(serial: String) async -> String {
        let power = await adb(["-s", serial, "shell", "dumpsys", "power"], timeout: 10).output
        let isAwake = power.contains("mWakefulness=Awake") || power.contains("Display Power: state=ON")
        let window = await adb(["-s", serial, "shell", "dumpsys", "window", "windows"], timeout: 10).output
        let focusLine = window.split(separator: "\n").first { $0.contains("mCurrentFocus") || $0.contains("mFocusedApp") }
        let focusedPackage = focusLine.flatMap { line -> String? in
            line.split(separator: " ").first { $0.contains("/") }.map { String($0.split(separator: "/").first ?? "") }
        }
        let appName = focusedPackage.flatMap { package in knownAndroidTVApps.first { $0.value == package }?.key } ?? focusedPackage
        return (isAwake ? "on" : "asleep") + (appName.map { ", showing \($0)" } ?? "")
    }

    @MainActor private static var mirrorProcesses: [String: Process] = [:]

    /// Opens the TV in a window on the Mac. Returns nil when it opened.
    @MainActor
    static func startMirroring(serial: String, title: String) -> String? {
        if let runningProcess = mirrorProcesses[serial], runningProcess.isRunning {
            return nil
        }
        guard let scrcpyPath = locateTool("scrcpy") else { return "scrcpy isn't installed; install the TV tools in Home → Smart Home." }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: scrcpyPath)
        process.arguments = ["-s", serial, "--window-title", title, "--stay-awake", "--max-size", "1920"]
        var environment = ProcessInfo.processInfo.environment
        // scrcpy finds adb on PATH.
        if let adbPath = locateTool("adb") {
            environment["ADB"] = adbPath
            environment["PATH"] = (adbPath as NSString).deletingLastPathComponent + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        }
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return "couldn't start scrcpy: \(error.localizedDescription)"
        }
        mirrorProcesses[serial] = process
        return nil
    }

    @MainActor
    static func stopMirroring(serial: String) {
        mirrorProcesses[serial]?.terminate()
        mirrorProcesses[serial] = nil
    }

    // MARK: - Roku (ECP)

    static func rokuRequest(host: String, path: String, method: String = "POST") async -> (Data, Int)? {
        guard let url = URL(string: "http://\(host):8060/\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 5
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func rokuPress(host: String, keyName: String) async -> Bool {
        guard let rokuKey = remoteKeys[keyName]?.rokuKey else { return false }
        return await rokuRequest(host: host, path: "keypress/\(rokuKey)")?.1 == 200
    }

    static func rokuType(host: String, text: String) async -> Bool {
        for character in text {
            let encoded = String(character).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            guard await rokuRequest(host: host, path: "keypress/Lit_\(encoded)")?.1 == 200 else { return false }
        }
        return true
    }

    /// Installed channels: name → id.
    static func rokuApps(host: String) async -> [String: String] {
        guard let (data, _) = await rokuRequest(host: host, path: "query/apps", method: "GET") else { return [:] }
        let xml = String(decoding: data, as: UTF8.self)
        var apps: [String: String] = [:]
        let pattern = try? NSRegularExpression(pattern: #"<app id="([^"]+)"[^>]*>([^<]+)</app>"#)
        pattern?.enumerateMatches(in: xml, range: NSRange(xml.startIndex..., in: xml)) { match, _, _ in
            guard let match, let idRange = Range(match.range(at: 1), in: xml), let nameRange = Range(match.range(at: 2), in: xml) else { return }
            apps[String(xml[nameRange]).lowercased()] = String(xml[idRange])
        }
        return apps
    }

    static func rokuOpenApp(host: String, name: String) async -> String {
        let apps = await rokuApps(host: host)
        let wantedName = name.lowercased()
        guard let appID = apps[wantedName] ?? apps.first(where: { $0.key.contains(wantedName) })?.value else {
            return apps.isEmpty
                ? "the Roku didn't answer. In its settings, set Control by mobile apps to Permissive."
                : "no \(name) channel on the Roku. It has: \(apps.keys.sorted().prefix(15).joined(separator: ", "))."
        }
        return await rokuRequest(host: host, path: "launch/\(appID)")?.1 == 200 ? "opened \(name) on the Roku." : "couldn't open \(name)."
    }

    static func rokuName(host: String) async -> String? {
        guard let (data, _) = await rokuRequest(host: host, path: "query/device-info", method: "GET") else { return nil }
        let xml = String(decoding: data, as: UTF8.self)
        for tag in ["user-device-name", "friendly-device-name", "model-name"] {
            if let start = xml.range(of: "<\(tag)>"), let end = xml.range(of: "</\(tag)>", range: start.upperBound..<xml.endIndex) {
                let value = String(xml[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return value }
            }
        }
        return "Roku"
    }

    /// Finds Rokus on the network (SSDP). Returns their IP addresses.
    static func discoverRokus(timeout: TimeInterval = 2.5) async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: ssdpSearch(searchTarget: "roku:ecp", timeout: timeout))
            }
        }
    }

    private static func ssdpSearch(searchTarget: String, timeout: TimeInterval) -> [String] {
        let socketDescriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketDescriptor >= 0 else { return [] }
        defer { close(socketDescriptor) }
        var receiveTimeout = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(socketDescriptor, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))

        var destination = sockaddr_in()
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = in_port_t(1900).bigEndian
        destination.sin_addr.s_addr = inet_addr("239.255.255.250")
        let message = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: \(searchTarget)\r\n\r\n"
        _ = message.withCString { messagePointer in
            withUnsafePointer(to: &destination) { destinationPointer in
                destinationPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    sendto(socketDescriptor, messagePointer, strlen(messagePointer), 0, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var addresses: Set<String> = []
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 2048)
        while Date() < deadline {
            let receivedCount = recv(socketDescriptor, &buffer, buffer.count, 0)
            guard receivedCount > 0 else { continue }
            let response = String(decoding: buffer[0..<receivedCount], as: UTF8.self)
            for line in response.split(separator: "\r\n") where line.lowercased().hasPrefix("location:") {
                if let url = URL(string: line.dropFirst("location:".count).trimmingCharacters(in: .whitespaces)), let host = url.host {
                    addresses.insert(host)
                }
            }
        }
        return addresses.sorted()
    }

    // MARK: - HDMI capture card (eyes for any TV)

    /// Video inputs that look like capture cards (external cameras).
    static func captureDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    /// One frame from a capture card, as JPEG.
    static func captureFrame(deviceID: String) async -> Data? {
        guard let device = AVCaptureDevice(uniqueID: deviceID) else { return nil }
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return nil }
        let grabber = CaptureFrameGrabber()
        return await grabber.grabFrame(from: device)
    }

    private final class CaptureFrameGrabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
        private let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "dottie.capture-card")
        private var continuation: CheckedContinuation<Data?, Never>?
        private var framesSeen = 0

        func grabFrame(from device: AVCaptureDevice) async -> Data? {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    self.continuation = continuation
                    guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
                        finish(with: nil)
                        return
                    }
                    session.addInput(input)
                    let output = AVCaptureVideoDataOutput()
                    output.setSampleBufferDelegate(self, queue: queue)
                    guard session.canAddOutput(output) else {
                        finish(with: nil)
                        return
                    }
                    session.addOutput(output)
                    session.startRunning()
                    queue.asyncAfter(deadline: .now() + 6) { [weak self] in self?.finish(with: nil) }
                }
            }
        }

        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            framesSeen += 1
            // The first frames are often black while the card settles.
            guard framesSeen >= 5, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let context = CIContext()
            guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
            finish(with: NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [.compressionFactor: 0.8]))
        }

        private func finish(with data: Data?) {
            guard let continuation else { return }
            self.continuation = nil
            session.stopRunning()
            continuation.resume(returning: data)
        }
    }

    // MARK: - CH9329 USB keyboard adapter (hands for any TV)

    /// Serial ports that could be a CH9329 adapter.
    static func keyboardAdapterPorts() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names.filter { $0.hasPrefix("cu.usbserial") || $0.hasPrefix("cu.wchusbserial") || $0.hasPrefix("cu.usbmodem") }
            .map { "/dev/\($0)" }.sorted()
    }

    /// Presses a remote button as a USB keyboard key on the TV.
    static func keyboardAdapterPress(port: String, keyName: String) -> Bool {
        guard let key = remoteKeys[keyName] else { return false }
        if let usage = key.keyboardUsage {
            return sendKeyboardReport(port: port, modifier: 0, usage: usage)
        }
        if let mediaBit = key.mediaKeyBit {
            // Media keys: report id 2, then the bit for the key; then release.
            let pressed = sendCH9329(port: port, command: 0x03, data: [0x02, mediaBit, 0x00, 0x00])
            usleep(60_000)
            let released = sendCH9329(port: port, command: 0x03, data: [0x02, 0x00, 0x00, 0x00])
            return pressed && released
        }
        if keyName == "home" {
            // Most TVs that take a keyboard treat Escape as back and the
            // Windows key as home.
            return sendKeyboardReport(port: port, modifier: 0x08, usage: 0x00)
        }
        return false
    }

    static func keyboardAdapterType(port: String, text: String) -> Bool {
        for character in text {
            guard let (modifier, usage) = keyboardUsage(for: character) else { continue }
            guard sendKeyboardReport(port: port, modifier: modifier, usage: usage) else { return false }
        }
        return true
    }

    private static func keyboardUsage(for character: Character) -> (UInt8, UInt8)? {
        let shift: UInt8 = 0x02
        if let letter = character.asciiValue, (97...122).contains(letter) { return (0, letter - 97 + 0x04) }
        if let letter = character.asciiValue, (65...90).contains(letter) { return (shift, letter - 65 + 0x04) }
        if let digit = character.asciiValue, (49...57).contains(digit) { return (0, digit - 49 + 0x1E) }
        let others: [Character: (UInt8, UInt8)] = [
            "0": (0, 0x27), " ": (0, 0x2C), "\n": (0, 0x28), "-": (0, 0x2D), "=": (0, 0x2E), ".": (0, 0x37), ",": (0, 0x36),
            "/": (0, 0x38), "'": (0, 0x34), ";": (0, 0x33), "!": (shift, 0x1E), "@": (shift, 0x1F), "?": (shift, 0x38),
            ":": (shift, 0x33), "_": (shift, 0x2D), "&": (shift, 0x24)
        ]
        return others[character]
    }

    private static func sendKeyboardReport(port: String, modifier: UInt8, usage: UInt8) -> Bool {
        let pressed = sendCH9329(port: port, command: 0x02, data: [modifier, 0, usage, 0, 0, 0, 0, 0])
        usleep(40_000)
        let released = sendCH9329(port: port, command: 0x02, data: [0, 0, 0, 0, 0, 0, 0, 0])
        usleep(20_000)
        return pressed && released
    }

    /// One CH9329 frame: 57 AB, address 00, command, length, data, checksum.
    private static func sendCH9329(port: String, command: UInt8, data: [UInt8]) -> Bool {
        let fileDescriptor = open(port, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fileDescriptor >= 0 else { return false }
        defer { close(fileDescriptor) }
        var settings = termios()
        tcgetattr(fileDescriptor, &settings)
        cfmakeraw(&settings)
        cfsetspeed(&settings, speed_t(B9600))
        settings.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tcsetattr(fileDescriptor, TCSANOW, &settings)
        var frame: [UInt8] = [0x57, 0xAB, 0x00, command, UInt8(data.count)] + data
        frame.append(UInt8(frame.reduce(0) { ($0 + Int($1)) } & 0xFF))
        return write(fileDescriptor, frame, frame.count) == frame.count
    }
}
