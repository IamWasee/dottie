//
//  DottieScreenLock.swift
//  leanring-buddy
//
//  Knows when the Mac's screen is locked. While it is, helpers, routines
//  and tools that don't need the screen keep going as usual, but jobs that
//  look at or click the screen wait: macOS doesn't let any app see or use
//  the screen behind the lock, and Dottie doesn't try to get around that.
//  They pick up again on their own once the user unlocks.
//
//  Also keeps the Mac awake while Dottie works (DottieKeepAwake): the Mac
//  doesn't sleep, and by default the screen stays on, so the screensaver
//  and the idle lock don't start in the middle of a job.
//

import AppKit
import Combine
import CoreGraphics
import Foundation
import IOKit.pwr_mgt

@MainActor
final class DottieScreenLock: ObservableObject {
    static let shared = DottieScreenLock()

    @Published private(set) var isLocked = false

    /// Called on the main actor each time the screen locks or unlocks.
    var onChange: ((_ isLocked: Bool) -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var unlockWaiters: [CheckedContinuation<Void, Never>] = []

    private init() {
        isLocked = Self.sessionSaysLocked()
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DottieScreenLock.shared.setLocked(true) }
        })
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DottieScreenLock.shared.setLocked(false) }
        })
    }

    /// Asks the login session directly (used at launch, before any
    /// notification has arrived).
    nonisolated static func sessionSaysLocked() -> Bool {
        guard let sessionDictionary = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let locked = sessionDictionary["CGSSessionScreenIsLocked"] as? Bool { return locked }
        if let locked = sessionDictionary["CGSSessionScreenIsLocked"] as? NSNumber { return locked.boolValue }
        return false
    }

    private func setLocked(_ newValue: Bool) {
        guard newValue != isLocked else { return }
        isLocked = newValue
        print(newValue ? "🔒 Screen locked: screen jobs will wait" : "🔓 Screen unlocked: screen jobs can carry on")
        if !newValue {
            let waiters = unlockWaiters
            unlockWaiters = []
            waiters.forEach { $0.resume() }
        }
        onChange?(newValue)
    }

    /// Returns right away when unlocked, otherwise once the user unlocks.
    func waitUntilUnlocked() async {
        guard isLocked else { return }
        await withCheckedContinuation { continuation in
            if isLocked {
                unlockWaiters.append(continuation)
            } else {
                continuation.resume()
            }
        }
    }
}

/// Keeps the Mac awake while Dottie works: a screen job, a helper's turn,
/// a 24/7 job, or away mode. The Mac never sleeps on its own then, and
/// unless the user turned it off in Settings the display stays on too, so
/// the screensaver never starts and an idle Mac never locks itself (macOS
/// locks on screensaver or display sleep, and nothing can see or click
/// the screen behind the lock). Released as soon as nothing needs it.
@MainActor
final class DottieKeepAwake: ObservableObject {
    static let shared = DottieKeepAwake()

    enum Reason: String, CaseIterable {
        case allDayJob = "a 24/7 job"
        case screenJob = "a screen job"
        case helperWork = "a helper's task"
        case awayMode = "away mode"
    }

    static let keepScreenOnDefaultsKey = "dottieKeepScreenOnWhileWorking"

    /// On unless the user turned it off (Settings → Working on its own).
    @Published var keepsScreenOnWhileWorking: Bool = UserDefaults.standard.object(forKey: DottieKeepAwake.keepScreenOnDefaultsKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(keepsScreenOnWhileWorking, forKey: Self.keepScreenOnDefaultsKey)
            updateAssertions()
        }
    }

    @Published private(set) var activeReasons: Set<Reason> = []

    private var systemSleepAssertionID: IOPMAssertionID = 0
    private var displaySleepAssertionID: IOPMAssertionID = 0
    private var isHoldingSystemAssertion = false
    private var isHoldingDisplayAssertion = false

    var isHoldingAssertion: Bool { isHoldingSystemAssertion }

    private init() {}

    /// The 24/7 jobs' switch (DottieKeepWorking).
    func setActive(_ shouldStayAwake: Bool) {
        hold(.allDayJob, shouldStayAwake)
    }

    func hold(_ reason: Reason, _ isNeeded: Bool) {
        let alreadyHeld = activeReasons.contains(reason)
        guard isNeeded != alreadyHeld else { return }
        if isNeeded {
            activeReasons.insert(reason)
            // Work starting while the screensaver runs (or the display is
            // asleep) brings the screen back first.
            if keepsScreenOnWhileWorking { wakeScreenIfIdle() }
        } else {
            activeReasons.remove(reason)
        }
        updateAssertions()
    }

    private var assertionReasonText: String {
        let reasonNames = Reason.allCases.filter { activeReasons.contains($0) }.map(\.rawValue)
        return "Dottie is working on " + reasonNames.joined(separator: " and ")
    }

    private func updateAssertions() {
        let needsSystemAwake = !activeReasons.isEmpty
        let needsScreenOn = needsSystemAwake && keepsScreenOnWhileWorking
        setAssertion(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            isNeeded: needsSystemAwake,
            assertionID: &systemSleepAssertionID,
            isHolding: &isHoldingSystemAssertion
        )
        setAssertion(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            isNeeded: needsScreenOn,
            assertionID: &displaySleepAssertionID,
            isHolding: &isHoldingDisplayAssertion
        )
    }

    private func setAssertion(_ assertionType: CFString, isNeeded: Bool, assertionID: inout IOPMAssertionID, isHolding: inout Bool) {
        if isNeeded && !isHolding {
            var newAssertionID: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                assertionType,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                assertionReasonText as CFString,
                &newAssertionID
            )
            if result == kIOReturnSuccess {
                assertionID = newAssertionID
                isHolding = true
                print("☕️ Keeping the Mac awake (\(assertionType)): \(assertionReasonText)")
            } else {
                print("⚠️ Couldn't keep the Mac awake (\(result))")
            }
        } else if !isNeeded && isHolding {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
            isHolding = false
            print("☕️ Released \(assertionType)")
        }
    }

    /// Ends the screensaver and wakes a sleeping display, the way a touch
    /// of the mouse would. Only while the Mac isn't locked: if the
    /// screensaver already asks for the password, macOS keeps the lock
    /// screen up and Dottie doesn't try to get past it.
    func wakeScreenIfIdle() {
        guard !DottieScreenLock.shared.isLocked else { return }
        var userActivityAssertionID: IOPMAssertionID = 0
        let result = IOPMAssertionDeclareUserActivity(
            "Dottie is starting work" as CFString,
            kIOPMUserActiveLocal,
            &userActivityAssertionID
        )
        if result == kIOReturnSuccess {
            // Declaring activity turns the display on; the assertion lapses
            // by itself, so it isn't released here.
            print("☀️ Woke the screen for Dottie's work")
        }
        // The screensaver runs as its own app; closing it is what a key
        // press does.
        let screenSaverBundleIdentifiers = ["com.apple.ScreenSaver.Engine", "com.apple.ScreenSaver.Engine.legacyScreenSaver"]
        for bundleIdentifier in screenSaverBundleIdentifiers {
            for screenSaverApp in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier) {
                screenSaverApp.terminate()
                print("☀️ Ended the screensaver so Dottie can see the screen")
            }
        }
    }
}
