//
//  DottieGameplayRecorder.swift
//  leanring-buddy
//
//  Records the user's own gameplay as training data for the reflex model:
//  every new frame of the screen (up to 30 a second) and, for each frame,
//  which keys and mouse buttons were held and how far the mouse moved since
//  the frame before. Raw input events are kept too, so the data can be
//  cleaned up and re-labelled later. Nothing leaves the Mac.
//
//  Saved in ~/Library/Application Support/Dottie/GameData/<session>/:
//    frames/000001.jpg …   the frames, at most 640 px on the long side
//    frames.jsonl          one line per frame: time, file, input snapshot
//    events.jsonl          one line per key, click, scroll or app switch
//    session.json          when, which display, frame count, duration
//

import AppKit
import Combine
import CoreImage
import Foundation
import ScreenCaptureKit

@MainActor
final class DottieGameplayRecorder: ObservableObject {
    static let shared = DottieGameplayRecorder()

    /// Frames are saved this large on the long side: enough for training
    /// at 224–320 px, small enough for hours of play (about 3 GB an hour).
    static let savedFrameMaximumDimension = 640
    static let maximumFramesPerSecond = 30
    /// Recording stops on its own when less than this much disk is free.
    nonisolated static let minimumFreeDiskBytes: Int64 = 2_000_000_000

    @Published private(set) var isRecording = false
    @Published private(set) var isStarting = false
    @Published private(set) var savedFrameCount = 0
    @Published private(set) var savedByteCount: Int64 = 0
    /// Why the last recording stopped or failed to start, when it wasn't
    /// the user's choice.
    @Published private(set) var problemMessage: String?

    private var captureStream: SCStream?
    private var frameOutput: DottieGameplayFrameOutput?
    private var sessionWriter: DottieGameplaySessionWriter?
    private var eventMonitors: [Any] = []
    private var appActivationObserver: NSObjectProtocol?
    private var progressTimer: Timer?

    static var gameDataFolderURL: URL {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupportURL
            .appendingPathComponent("Dottie", isDirectory: true)
            .appendingPathComponent("GameData", isDirectory: true)
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            Task { await startRecording() }
        }
    }

    func openGameDataFolder() {
        try? FileManager.default.createDirectory(at: Self.gameDataFolderURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.gameDataFolderURL)
    }

    func startRecording() async {
        guard !isRecording, !isStarting else { return }
        isStarting = true
        problemMessage = nil
        defer { isStarting = false }

        // Record the display the user is playing on: the one with the pointer.
        let pointerScreen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        guard let pointerScreen else {
            problemMessage = "Couldn't find a display to record."
            return
        }

        let shareableContent: SCShareableContent
        do {
            shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            problemMessage = "Dottie needs Screen Recording permission to record gameplay."
            return
        }
        let pointerDisplayID = pointerScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = shareableContent.displays.first(where: { $0.displayID == pointerDisplayID }) ?? shareableContent.displays.first else {
            problemMessage = "Couldn't find a display to record."
            return
        }

        let sessionFolderName = Self.sessionFolderName(for: Date())
        let sessionFolderURL = Self.gameDataFolderURL.appendingPathComponent(sessionFolderName, isDirectory: true)
        let sessionStartUptime = ProcessInfo.processInfo.systemUptime
        guard let writer = DottieGameplaySessionWriter(sessionFolderURL: sessionFolderURL, sessionStartUptime: sessionStartUptime) else {
            problemMessage = "Couldn't create the folder for the recording."
            return
        }

        // Leave Dottie's own windows (notch, cursor, panels) out of the frames.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = shareableContent.windows.filter { $0.owningApplication?.bundleIdentifier == ownBundleIdentifier }
        let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)

        let configuration = SCStreamConfiguration()
        let pointsToPixels = pointerScreen.backingScaleFactor
        let nativeWidth = CGFloat(display.width) * pointsToPixels
        let nativeHeight = CGFloat(display.height) * pointsToPixels
        let downscale = min(1, CGFloat(Self.savedFrameMaximumDimension) / max(nativeWidth, nativeHeight))
        configuration.width = Int(nativeWidth * downscale)
        configuration.height = Int(nativeHeight * downscale)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Self.maximumFramesPerSecond))
        configuration.queueDepth = 6
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false

        let inputState = DottieGameplayInputState()
        inputState.setFrontmostApplication(NSWorkspace.shared.frontmostApplication)
        let output = DottieGameplayFrameOutput(sessionWriter: writer, inputState: inputState)
        output.onDiskNearlyFull = { [weak self] in
            Task { @MainActor in
                self?.stopRecording(problemMessage: "Stopped recording: the disk is almost full.")
            }
        }

        // Hold on to the output and writer before frames can start arriving.
        frameOutput = output
        sessionWriter = writer
        do {
            let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "dottie.gameplay.frames"))
            try await stream.startCapture()
            captureStream = stream
        } catch {
            frameOutput = nil
            sessionWriter = nil
            writer.discard()
            problemMessage = "Couldn't start recording the screen: \(error.localizedDescription)"
            return
        }

        writer.writeSessionDetails([
            "started_at": ISO8601DateFormatter().string(from: Date()),
            "display_points": ["width": display.width, "height": display.height],
            "frame_pixels": ["width": configuration.width, "height": configuration.height],
            "maximum_frames_per_second": Self.maximumFramesPerSecond,
            "frontmost_app": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
        ])

        startWatchingInput(inputState: inputState, sessionWriter: writer)
        savedFrameCount = 0
        savedByteCount = 0
        isRecording = true
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshProgress()
            }
        }
    }

    func stopRecording() {
        stopRecording(problemMessage: nil)
    }

    private func stopRecording(problemMessage stopReason: String?) {
        guard isRecording else { return }
        if let captureStream {
            Task { try? await captureStream.stopCapture() }
        }
        captureStream = nil
        for eventMonitor in eventMonitors {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitors = []
        if let appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appActivationObserver)
        }
        appActivationObserver = nil
        progressTimer?.invalidate()
        progressTimer = nil
        refreshProgress()
        sessionWriter?.finish(savedFrameCount: frameOutput?.savedFrameCount ?? savedFrameCount)
        sessionWriter = nil
        frameOutput = nil
        isRecording = false
        problemMessage = stopReason
    }

    private func refreshProgress() {
        guard let frameOutput else { return }
        savedFrameCount = frameOutput.savedFrameCount
        savedByteCount = frameOutput.savedByteCount
    }

    /// Global monitors see input going to other apps (the game). Like
    /// "watch me play", this relies on Dottie's Accessibility permission.
    private func startWatchingInput(inputState: DottieGameplayInputState, sessionWriter: DottieGameplaySessionWriter) {
        let watchedEventTypes: NSEvent.EventTypeMask = [
            .keyDown, .keyUp, .flagsChanged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .scrollWheel,
        ]
        if let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: watchedEventTypes, handler: { event in
            Self.record(event, inputState: inputState, sessionWriter: sessionWriter)
        }) {
            eventMonitors.append(globalMonitor)
        }

        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            let activatedApplication = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            inputState.setFrontmostApplication(activatedApplication)
            sessionWriter.appendEvent([
                "type": "app_switch",
                "app": activatedApplication?.bundleIdentifier ?? "",
            ], uptime: ProcessInfo.processInfo.systemUptime)
        }
    }

    private static func record(_ event: NSEvent, inputState: DottieGameplayInputState, sessionWriter: DottieGameplaySessionWriter) {
        switch event.type {
        case .keyDown:
            // Held keys repeat; the hold is already known from the first press.
            guard !event.isARepeat else { return }
            let keyName = Self.keyName(for: event)
            inputState.pressKey(keyName)
            sessionWriter.appendEvent(["type": "key_down", "key": keyName, "key_code": Int(event.keyCode)], uptime: event.timestamp)
        case .keyUp:
            let keyName = Self.keyName(for: event)
            inputState.releaseKey(keyName)
            sessionWriter.appendEvent(["type": "key_up", "key": keyName, "key_code": Int(event.keyCode)], uptime: event.timestamp)
        case .flagsChanged:
            let heldModifierNames = Self.modifierNames(in: event.modifierFlags)
            inputState.setHeldModifiers(heldModifierNames)
            sessionWriter.appendEvent(["type": "modifiers", "held": heldModifierNames.sorted()], uptime: event.timestamp)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let buttonName = Self.mouseButtonName(for: event)
            inputState.pressMouseButton(buttonName)
            sessionWriter.appendEvent(["type": "mouse_down", "button": buttonName], uptime: event.timestamp)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            let buttonName = Self.mouseButtonName(for: event)
            inputState.releaseMouseButton(buttonName)
            sessionWriter.appendEvent(["type": "mouse_up", "button": buttonName], uptime: event.timestamp)
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            // Deltas still arrive while a game has locked the pointer for
            // camera control, which is what turning the camera looks like.
            inputState.addMouseMovement(deltaX: event.deltaX, deltaY: event.deltaY, location: NSEvent.mouseLocation)
        case .scrollWheel:
            inputState.addScroll(deltaY: event.scrollingDeltaY)
        default:
            break
        }
    }

    private static func keyName(for event: NSEvent) -> String {
        switch event.keyCode {
        case 49: return "space"
        case 36: return "return"
        case 48: return "tab"
        case 53: return "escape"
        case 51: return "delete"
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        default:
            let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
            return characters.isEmpty ? "key \(event.keyCode)" : characters
        }
    }

    private static func modifierNames(in modifierFlags: NSEvent.ModifierFlags) -> Set<String> {
        var heldModifierNames: Set<String> = []
        if modifierFlags.contains(.shift) { heldModifierNames.insert("shift") }
        if modifierFlags.contains(.control) { heldModifierNames.insert("control") }
        if modifierFlags.contains(.option) { heldModifierNames.insert("option") }
        if modifierFlags.contains(.command) { heldModifierNames.insert("command") }
        return heldModifierNames
    }

    private static func mouseButtonName(for event: NSEvent) -> String {
        switch event.type {
        case .leftMouseDown, .leftMouseUp: return "left"
        case .rightMouseDown, .rightMouseUp: return "right"
        default: return "button \(event.buttonNumber)"
        }
    }

    private static func sessionFolderName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: date)
    }
}

// MARK: - Input state

/// What the user is holding right now, plus mouse movement since the last
/// frame. Written from the main thread by event monitors, read and reset
/// from the frame queue once per frame.
final class DottieGameplayInputState: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var heldKeys: Set<String> = []
    nonisolated(unsafe) private var heldModifiers: Set<String> = []
    nonisolated(unsafe) private var heldMouseButtons: Set<String> = []
    nonisolated(unsafe) private var mouseDeltaXSinceLastFrame: Double = 0
    nonisolated(unsafe) private var mouseDeltaYSinceLastFrame: Double = 0
    nonisolated(unsafe) private var scrollDeltaYSinceLastFrame: Double = 0
    nonisolated(unsafe) private var latestMouseLocation: CGPoint = .zero
    nonisolated(unsafe) private var frontmostApplicationBundleIdentifier = ""

    nonisolated init() {}

    nonisolated func pressKey(_ keyName: String) {
        withLock { heldKeys.insert(keyName) }
    }

    nonisolated func releaseKey(_ keyName: String) {
        withLock { _ = heldKeys.remove(keyName) }
    }

    nonisolated func setHeldModifiers(_ modifierNames: Set<String>) {
        withLock { heldModifiers = modifierNames }
    }

    nonisolated func pressMouseButton(_ buttonName: String) {
        withLock { heldMouseButtons.insert(buttonName) }
    }

    nonisolated func releaseMouseButton(_ buttonName: String) {
        withLock { _ = heldMouseButtons.remove(buttonName) }
    }

    nonisolated func addMouseMovement(deltaX: CGFloat, deltaY: CGFloat, location: CGPoint) {
        withLock {
            mouseDeltaXSinceLastFrame += Double(deltaX)
            mouseDeltaYSinceLastFrame += Double(deltaY)
            latestMouseLocation = location
        }
    }

    nonisolated func addScroll(deltaY: CGFloat) {
        withLock { scrollDeltaYSinceLastFrame += Double(deltaY) }
    }

    nonisolated func setFrontmostApplication(_ application: NSRunningApplication?) {
        let bundleIdentifier = application?.bundleIdentifier ?? ""
        withLock { frontmostApplicationBundleIdentifier = bundleIdentifier }
    }

    /// The input at this frame, as its fields in frames.jsonl. Mouse
    /// movement and scroll start over from zero for the next frame.
    nonisolated func takeSnapshotForFrame() -> [String: Any] {
        withLock {
            let snapshotFields: [String: Any] = [
                "held_keys": heldKeys.union(heldModifiers).sorted(),
                "held_mouse_buttons": heldMouseButtons.sorted(),
                "mouse_dx": mouseDeltaXSinceLastFrame,
                "mouse_dy": mouseDeltaYSinceLastFrame,
                "mouse_x": Double(latestMouseLocation.x),
                "mouse_y": Double(latestMouseLocation.y),
                "scroll_dy": scrollDeltaYSinceLastFrame,
                "app": frontmostApplicationBundleIdentifier,
            ]
            mouseDeltaXSinceLastFrame = 0
            mouseDeltaYSinceLastFrame = 0
            scrollDeltaYSinceLastFrame = 0
            return snapshotFields
        }
    }

    nonisolated private func withLock<Result>(_ body: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

// MARK: - Frames

/// Receives frames from ScreenCaptureKit on its own queue, saves each new
/// one as a JPEG and writes its line in frames.jsonl.
final class DottieGameplayFrameOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let sessionWriter: DottieGameplaySessionWriter
    private let inputState: DottieGameplayInputState
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private let lock = NSLock()
    nonisolated(unsafe) private var frameCount = 0
    nonisolated(unsafe) private var byteCount: Int64 = 0
    nonisolated(unsafe) private var hasReportedDiskNearlyFull = false
    nonisolated(unsafe) var onDiskNearlyFull: (@Sendable () -> Void)?

    nonisolated init(sessionWriter: DottieGameplaySessionWriter, inputState: DottieGameplayInputState) {
        self.sessionWriter = sessionWriter
        self.inputState = inputState
    }

    nonisolated var savedFrameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return frameCount
    }

    nonisolated var savedByteCount: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return byteCount
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, Self.isCompleteFrame(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let frameUptime = ProcessInfo.processInfo.systemUptime
        let inputSnapshotFields = inputState.takeSnapshotForFrame()

        let frameImage = CIImage(cvPixelBuffer: pixelBuffer)
        let compressionOptions = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.7]
        guard let jpegData = imageContext.jpegRepresentation(of: frameImage, colorSpace: colorSpace, options: compressionOptions) else { return }

        lock.lock()
        frameCount += 1
        let frameNumber = frameCount
        byteCount += Int64(jpegData.count)
        lock.unlock()

        let frameFileName = String(format: "%06d.jpg", frameNumber)
        var frameLine = inputSnapshotFields
        frameLine["frame"] = frameNumber
        frameLine["file"] = "frames/\(frameFileName)"
        frameLine["t"] = frameUptime - sessionWriter.sessionStartUptime
        sessionWriter.saveFrame(jpegData: jpegData, fileName: frameFileName, line: frameLine)

        // Checking free space is cheap but not free: every 300 frames.
        if frameNumber % 300 == 0, !sessionWriter.hasEnoughFreeDiskSpace(minimumFreeBytes: DottieGameplayRecorder.minimumFreeDiskBytes) {
            lock.lock()
            let shouldReport = !hasReportedDiskNearlyFull
            hasReportedDiskNearlyFull = true
            lock.unlock()
            if shouldReport {
                onDiskNearlyFull?()
            }
        }
    }

    /// ScreenCaptureKit also sends "nothing changed" frames without pixels.
    nonisolated private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRawValue = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRawValue) else { return false }
        return status == .complete
    }
}

// MARK: - Files

/// Owns one session folder and writes to it on a serial queue, so frames
/// and input events never block the screen capture or the main thread.
final class DottieGameplaySessionWriter: @unchecked Sendable {
    let sessionFolderURL: URL
    let sessionStartUptime: TimeInterval
    private let framesFolderURL: URL
    private let writeQueue = DispatchQueue(label: "dottie.gameplay.writer")
    private let framesLogHandle: FileHandle
    private let eventsLogHandle: FileHandle
    nonisolated(unsafe) private var sessionDetails: [String: Any] = [:]
    /// Set once the session is closed, so late frames from a stopping
    /// stream are dropped instead of written into a closed log.
    nonisolated(unsafe) private var isFinished = false

    nonisolated init?(sessionFolderURL: URL, sessionStartUptime: TimeInterval) {
        self.sessionFolderURL = sessionFolderURL
        self.sessionStartUptime = sessionStartUptime
        framesFolderURL = sessionFolderURL.appendingPathComponent("frames", isDirectory: true)
        let framesLogURL = sessionFolderURL.appendingPathComponent("frames.jsonl")
        let eventsLogURL = sessionFolderURL.appendingPathComponent("events.jsonl")
        do {
            try FileManager.default.createDirectory(at: framesFolderURL, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: framesLogURL.path, contents: nil)
            FileManager.default.createFile(atPath: eventsLogURL.path, contents: nil)
            framesLogHandle = try FileHandle(forWritingTo: framesLogURL)
            eventsLogHandle = try FileHandle(forWritingTo: eventsLogURL)
        } catch {
            return nil
        }
    }

    nonisolated func writeSessionDetails(_ details: [String: Any]) {
        writeQueue.async {
            self.sessionDetails = details
            self.saveSessionDetails()
        }
    }

    nonisolated func saveFrame(jpegData: Data, fileName: String, line: [String: Any]) {
        writeQueue.async {
            guard !self.isFinished else { return }
            try? jpegData.write(to: self.framesFolderURL.appendingPathComponent(fileName))
            self.appendLine(line, to: self.framesLogHandle)
        }
    }

    nonisolated func appendEvent(_ event: [String: Any], uptime: TimeInterval) {
        var eventLine = event
        eventLine["t"] = uptime - sessionStartUptime
        writeQueue.async {
            guard !self.isFinished else { return }
            self.appendLine(eventLine, to: self.eventsLogHandle)
        }
    }

    nonisolated func hasEnoughFreeDiskSpace(minimumFreeBytes: Int64) -> Bool {
        guard let resourceValues = try? sessionFolderURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let availableBytes = resourceValues.volumeAvailableCapacityForImportantUsage else { return true }
        return availableBytes > minimumFreeBytes
    }

    /// Writes the closing details once every queued frame is on disk.
    nonisolated func finish(savedFrameCount: Int) {
        let endUptime = ProcessInfo.processInfo.systemUptime
        writeQueue.async {
            guard !self.isFinished else { return }
            self.isFinished = true
            self.sessionDetails["ended_at"] = ISO8601DateFormatter().string(from: Date())
            self.sessionDetails["duration_seconds"] = endUptime - self.sessionStartUptime
            self.sessionDetails["frame_count"] = savedFrameCount
            self.saveSessionDetails()
            try? self.framesLogHandle.close()
            try? self.eventsLogHandle.close()
        }
    }

    /// Closes and deletes a session that never recorded anything.
    nonisolated func discard() {
        writeQueue.async {
            self.isFinished = true
            try? self.framesLogHandle.close()
            try? self.eventsLogHandle.close()
            try? FileManager.default.removeItem(at: self.sessionFolderURL)
        }
    }

    nonisolated private func saveSessionDetails() {
        guard let detailsData = try? JSONSerialization.data(withJSONObject: sessionDetails, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? detailsData.write(to: sessionFolderURL.appendingPathComponent("session.json"), options: .atomic)
    }

    nonisolated private func appendLine(_ line: [String: Any], to fileHandle: FileHandle) {
        guard var lineData = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        lineData.append(0x0A)
        try? fileHandle.write(contentsOf: lineData)
    }
}
