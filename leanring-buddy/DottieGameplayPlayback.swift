//
//  DottieGameplayPlayback.swift
//  leanring-buddy
//
//  "Do what I recorded": plays a gameplay recording back into the game,
//  pressing the same keys and mouse buttons and moving the mouse by the
//  same amounts with the same timing, so a routine the user recorded once
//  (a sell loop, a shot for a commercial) can be done again by voice.
//
//  Recordings (DottieGameplayRecorder) keep key and button presses in
//  events.jsonl and mouse movement per frame in frames.jsonl; both are
//  merged into one timeline here. Dottie's own talk shortcut is left out:
//  the user holds it to say "start recording" and "stop recording", and
//  playing it back would start talking to Dottie mid-game.
//

import AppKit
import Carbon.HIToolbox
import Foundation

@MainActor
final class DottieGameplayPlayback {
    static let shared = DottieGameplayPlayback()

    struct SavedRecording {
        let folderURL: URL
        /// The name the user gave it ("sell loop"), or its start time.
        let name: String
        let startedAt: Date?
        let durationSeconds: Double
    }

    private enum TimelineAction {
        case key(keyCode: CGKeyCode, isDown: Bool)
        case shift(isDown: Bool)
        case mouseButton(button: String, isDown: Bool)
        case mouseMove(deltaX: Double, deltaY: Double)
    }

    private struct TimelineEntry {
        let secondsFromStart: Double
        let action: TimelineAction
    }

    private(set) var isPlaying = false
    private var playbackTask: Task<Void, Never>?

    // MARK: - Finding recordings

    static func savedRecordings() -> [SavedRecording] {
        let sessionFolderURLs = (try? FileManager.default.contentsOfDirectory(at: DottieGameplayRecorder.gameDataFolderURL, includingPropertiesForKeys: nil)) ?? []
        let isoFormatter = ISO8601DateFormatter()
        let recordings: [SavedRecording] = sessionFolderURLs.compactMap { sessionFolderURL in
            guard let detailsData = try? Data(contentsOf: sessionFolderURL.appendingPathComponent("session.json")),
                  let details = try? JSONSerialization.jsonObject(with: detailsData) as? [String: Any] else { return nil }
            let startedAt = (details["started_at"] as? String).flatMap { isoFormatter.date(from: $0) }
            let givenName = (details["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            return SavedRecording(
                folderURL: sessionFolderURL,
                name: givenName.isEmpty ? sessionFolderURL.lastPathComponent : givenName,
                startedAt: startedAt,
                durationSeconds: (details["duration_seconds"] as? NSNumber)?.doubleValue ?? 0
            )
        }
        return recordings.sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
    }

    /// The recording the user means: by name, or the newest one when the
    /// name is empty or "last".
    static func recording(named spokenName: String) -> SavedRecording? {
        let recordings = savedRecordings().filter { $0.durationSeconds > 0 }
        let lowercasedName = spokenName.lowercased().trimmingCharacters(in: .whitespaces)
        if lowercasedName.isEmpty || ["last", "latest", "newest", "last one", "the last one", "that"].contains(lowercasedName) {
            return recordings.first
        }
        return recordings.first { $0.name.lowercased() == lowercasedName }
            ?? recordings.first { $0.name.lowercased().contains(lowercasedName) || lowercasedName.contains($0.name.lowercased()) }
    }

    // MARK: - Playing

    /// Starts playing a recording back. Returns what to tell the user.
    func play(_ recording: SavedRecording) async -> String {
        guard DottieScreenActionPerformer.canPostEvents else {
            return "Dottie needs Accessibility access to press keys in games."
        }
        guard !isPlaying else { return "already playing a recording." }
        let timeline = Self.timeline(of: recording)
        guard !timeline.isEmpty else { return "that recording has no keys or mouse moves to play back." }

        // The game the recording was made in comes to the front first, so
        // the keys don't land in another app.
        if let recordedAppBundleIdentifier = Self.recordedAppBundleIdentifier(of: recording),
           recordedAppBundleIdentifier != Bundle.main.bundleIdentifier,
           let recordedApp = NSRunningApplication.runningApplications(withBundleIdentifier: recordedAppBundleIdentifier).first {
            recordedApp.activate()
            try? await Task.sleep(nanoseconds: 600_000_000)
        }

        isPlaying = true
        playbackTask = Task { @MainActor [weak self] in
            await self?.run(timeline)
            self?.isPlaying = false
            self?.playbackTask = nil
        }
        let durationSeconds = timeline.last?.secondsFromStart ?? 0
        return "playing \(recording.name) back now (about \(Int(durationSeconds.rounded())) seconds). say stop to end it."
    }

    /// Ends playback and lets go of everything it was holding. True when
    /// something was playing.
    @discardableResult
    func stop() -> Bool {
        guard let playbackTask else { return false }
        playbackTask.cancel()
        self.playbackTask = nil
        isPlaying = false
        return true
    }

    private func run(_ timeline: [TimelineEntry]) async {
        let eventSource = CGEventSource(stateID: .hidSystemState)
        var heldKeyCodes: Set<CGKeyCode> = []
        var isShiftHeld = false
        var heldMouseButtons: Set<String> = []
        var pointerLocation = Self.quartzPointerLocation()
        let playbackStartedAt = ProcessInfo.processInfo.systemUptime

        for entry in timeline {
            guard !Task.isCancelled else { break }
            let secondsUntilEntry = entry.secondsFromStart - (ProcessInfo.processInfo.systemUptime - playbackStartedAt)
            if secondsUntilEntry > 0.002 {
                try? await Task.sleep(nanoseconds: UInt64(secondsUntilEntry * 1_000_000_000))
            }
            guard !Task.isCancelled else { break }
            switch entry.action {
            case .key(let keyCode, let isDown):
                let keyEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: isDown)
                if isShiftHeld {
                    keyEvent?.flags = .maskShift
                }
                keyEvent?.post(tap: .cghidEventTap)
                if isDown {
                    heldKeyCodes.insert(keyCode)
                } else {
                    heldKeyCodes.remove(keyCode)
                }
            case .shift(let isDown):
                _ = DottieScreenActionPerformer.setKey("shift", isDown: isDown)
                isShiftHeld = isDown
            case .mouseButton(let button, let isDown):
                Self.postMouseButton(button, isDown: isDown, at: pointerLocation, eventSource: eventSource)
                if isDown {
                    heldMouseButtons.insert(button)
                } else {
                    heldMouseButtons.remove(button)
                }
            case .mouseMove(let deltaX, let deltaY):
                pointerLocation = CGPoint(x: pointerLocation.x + deltaX, y: pointerLocation.y + deltaY)
                // Dragging while a button is held, so a right-drag camera
                // turns the same way it did when recorded.
                let moveType: CGEventType = heldMouseButtons.contains("right") ? .rightMouseDragged
                    : heldMouseButtons.contains("left") ? .leftMouseDragged : .mouseMoved
                let moveButton: CGMouseButton = heldMouseButtons.contains("right") ? .right : .left
                let moveEvent = CGEvent(mouseEventSource: eventSource, mouseType: moveType, mouseCursorPosition: pointerLocation, mouseButton: moveButton)
                moveEvent?.setIntegerValueField(.mouseEventDeltaX, value: Int64(deltaX.rounded()))
                moveEvent?.setIntegerValueField(.mouseEventDeltaY, value: Int64(deltaY.rounded()))
                moveEvent?.post(tap: .cghidEventTap)
            }
        }

        // Nothing stays held after the end or a stop.
        for heldKeyCode in heldKeyCodes {
            CGEvent(keyboardEventSource: eventSource, virtualKey: heldKeyCode, keyDown: false)?.post(tap: .cghidEventTap)
        }
        if isShiftHeld {
            _ = DottieScreenActionPerformer.setKey("shift", isDown: false)
        }
        for heldMouseButton in heldMouseButtons {
            Self.postMouseButton(heldMouseButton, isDown: false, at: pointerLocation, eventSource: eventSource)
        }
    }

    private static func postMouseButton(_ button: String, isDown: Bool, at location: CGPoint, eventSource: CGEventSource?) {
        let mouseType: CGEventType
        let mouseButton: CGMouseButton
        switch button {
        case "right":
            mouseType = isDown ? .rightMouseDown : .rightMouseUp
            mouseButton = .right
        case "left":
            mouseType = isDown ? .leftMouseDown : .leftMouseUp
            mouseButton = .left
        default:
            mouseType = isDown ? .otherMouseDown : .otherMouseUp
            mouseButton = .center
        }
        CGEvent(mouseEventSource: eventSource, mouseType: mouseType, mouseCursorPosition: location, mouseButton: mouseButton)?
            .post(tap: .cghidEventTap)
    }

    /// The pointer in Quartz coordinates (top-left origin), which mouse
    /// events use.
    private static func quartzPointerLocation() -> CGPoint {
        let appKitLocation = NSEvent.mouseLocation
        let primaryDisplayHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: appKitLocation.x, y: primaryDisplayHeight - appKitLocation.y)
    }

    // MARK: - Reading a recording

    private static func recordedAppBundleIdentifier(of recording: SavedRecording) -> String? {
        guard let detailsData = try? Data(contentsOf: recording.folderURL.appendingPathComponent("session.json")),
              let details = try? JSONSerialization.jsonObject(with: detailsData) as? [String: Any],
              let bundleIdentifier = details["frontmost_app"] as? String, !bundleIdentifier.isEmpty else { return nil }
        return bundleIdentifier
    }

    private static func jsonLines(in fileURL: URL) -> [[String: Any]] {
        guard let fileText = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return fileText.split(separator: "\n").compactMap { line in
            guard let lineData = line.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
        }
    }

    /// Every press, release and mouse move in time order, starting at the
    /// first one, without the talk shortcut and anything after the user
    /// last held it (that's them saying "stop recording").
    private static func timeline(of recording: SavedRecording) -> [TimelineEntry] {
        var entries: [TimelineEntry] = []
        var lastTalkShortcutAt: Double?
        var isControlOrCommandHeld = false
        let ownBundleIdentifier = Bundle.main.bundleIdentifier ?? ""
        var isOwnAppInFront = false

        for event in jsonLines(in: recording.folderURL.appendingPathComponent("events.jsonl")) {
            guard let eventType = event["type"] as? String,
                  let secondsFromStart = (event["t"] as? NSNumber)?.doubleValue else { continue }
            switch eventType {
            case "app_switch":
                isOwnAppInFront = (event["app"] as? String) == ownBundleIdentifier
            case "modifiers":
                let heldModifiers = Set(event["held"] as? [String] ?? [])
                if heldModifiers.contains("control") && heldModifiers.contains("option") {
                    lastTalkShortcutAt = secondsFromStart
                }
                isControlOrCommandHeld = heldModifiers.contains("control") || heldModifiers.contains("command")
                // Only shift is played back: control, option and command
                // are app and system shortcuts, not game controls.
                entries.append(TimelineEntry(secondsFromStart: secondsFromStart, action: .shift(isDown: heldModifiers.contains("shift"))))
            case "key_down", "key_up":
                guard !isControlOrCommandHeld, !isOwnAppInFront,
                      let keyCode = (event["key_code"] as? NSNumber)?.intValue else { continue }
                entries.append(TimelineEntry(secondsFromStart: secondsFromStart, action: .key(keyCode: CGKeyCode(keyCode), isDown: eventType == "key_down")))
            case "mouse_down", "mouse_up":
                guard !isOwnAppInFront, let button = event["button"] as? String else { continue }
                entries.append(TimelineEntry(secondsFromStart: secondsFromStart, action: .mouseButton(button: button, isDown: eventType == "mouse_down")))
            default:
                continue
            }
        }
        for frameLine in jsonLines(in: recording.folderURL.appendingPathComponent("frames.jsonl")) {
            guard let secondsFromStart = (frameLine["t"] as? NSNumber)?.doubleValue else { continue }
            let deltaX = (frameLine["mouse_dx"] as? NSNumber)?.doubleValue ?? 0
            let deltaY = (frameLine["mouse_dy"] as? NSNumber)?.doubleValue ?? 0
            guard abs(deltaX) >= 0.5 || abs(deltaY) >= 0.5 else { continue }
            entries.append(TimelineEntry(secondsFromStart: secondsFromStart, action: .mouseMove(deltaX: deltaX, deltaY: deltaY)))
        }
        entries.sort { $0.secondsFromStart < $1.secondsFromStart }

        // The end of the recording is the user holding the talk shortcut to
        // say "stop recording": cut there when it's near the end.
        let recordingEndSeconds = entries.last?.secondsFromStart ?? 0
        if let lastTalkShortcutAt, recordingEndSeconds - lastTalkShortcutAt < 20 {
            entries.removeAll { $0.secondsFromStart >= lastTalkShortcutAt }
        }
        // Start at the first real input, not when recording began.
        let firstMeaningfulEntrySeconds = entries.first { entry in
            if case .shift(let isDown) = entry.action { return isDown }
            return true
        }?.secondsFromStart ?? 0
        return entries
            .filter { $0.secondsFromStart >= firstMeaningfulEntrySeconds }
            .map { TimelineEntry(secondsFromStart: $0.secondsFromStart - firstMeaningfulEntrySeconds, action: $0.action) }
    }
}
