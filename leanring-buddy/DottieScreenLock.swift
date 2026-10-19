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
//  Also keeps the Mac awake while a 24/7 job runs (DottieKeepAwake).
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

/// Keeps the Mac from going to sleep on its own while a 24/7 job runs. The
/// display may still sleep. Released as soon as nothing needs it.
@MainActor
final class DottieKeepAwake {
    static let shared = DottieKeepAwake()

    private var assertionID: IOPMAssertionID = 0
    private(set) var isHoldingAssertion = false

    private init() {}

    func setActive(_ shouldStayAwake: Bool, reason: String = "Dottie is working on a 24/7 job") {
        if shouldStayAwake && !isHoldingAssertion {
            var newAssertionID: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &newAssertionID
            )
            if result == kIOReturnSuccess {
                assertionID = newAssertionID
                isHoldingAssertion = true
                print("☕️ Keeping the Mac awake for 24/7 work")
            } else {
                print("⚠️ Couldn't keep the Mac awake (\(result))")
            }
        } else if !shouldStayAwake && isHoldingAssertion {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
            isHoldingAssertion = false
            print("☕️ Let the Mac sleep again")
        }
    }
}
