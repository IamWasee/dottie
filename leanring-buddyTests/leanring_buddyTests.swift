//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//

import Testing
@testable import Dottie

struct leanring_buddyTests {

    @Test @MainActor func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @Test @MainActor func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @Test @MainActor func grantedPermissionNeedsNoPrompt() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: true,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .alreadyGranted)
    }
}
