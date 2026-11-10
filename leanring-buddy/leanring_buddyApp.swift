//
//  leanring_buddyApp.swift
//  leanring-buddy
//
//  Dottie is a normal Mac app: it has a Dock icon, shows in Cmd+Tab and
//  in Force Quit (Option+Cmd+Esc), and opening it shows the Home window.
//  The menu bar icon, the notch and the floating panel still work the same.
//

import ServiceManagement
import SwiftUI

@main
struct leanring_buddyApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // Every window is managed by the AppDelegate (Home, the panel, the
        // notch). This empty Settings scene satisfies SwiftUI's requirement
        // for at least one scene; Dottie > Settings… (cmd+,) opens Home's
        // Settings page instead of it.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appDelegate.openHomeWindow(on: .settings)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Dottie") {
                    appDelegate.openHomeWindow(on: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    private let companionManager = CompanionManager()

    /// True when Xcode opened the app only to host the unit tests. The tests
    /// check pure logic, so nothing should start: no menu bar icon, no login
    /// item, no update checks, no permission prompts on the test machine.
    private static var isHostingUnitTests: Bool {
        let processEnvironment = ProcessInfo.processInfo.environment
        return processEnvironment["XCTestConfigurationFilePath"] != nil
            || processEnvironment["XCTestBundlePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Self.isHostingUnitTests {
            DottieLog.notice("🎯 Dottie: Hosting unit tests, not starting the companion")
            return
        }

        DottieLog.notice("🎯 Dottie: Starting...")
        DottieLog.notice("🎯 Dottie: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        ClickyAnalytics.configure()
        ClickyAnalytics.trackAppOpened()
        DottieGameWorldMap.removeOldFlatMaps()

        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        companionManager.start()
        // Auto-open the panel if the user still needs to do something:
        // either they haven't onboarded yet, or permissions were revoked.
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            menuBarPanelManager?.showPanelOnLaunch()
        }
        registerAsLoginItemIfNeeded()
        // Updates come from GitHub releases (Settings → Updates).
        DottieUpdater.shared.startPeriodicChecks()

        // Opened by the user (Dock, Launchpad, Finder, Spotlight): show Home,
        // like any app. Started at login: stay in the menu bar and notch so
        // a window doesn't pop up every time the Mac starts. First run keeps
        // the panel above, which walks through onboarding.
        if companionManager.hasCompletedOnboarding && !Self.wasLaunchedAsLoginItem {
            companionManager.openHomeWindow()
        }
    }

    /// Clicking the Dock icon (or opening Dottie again while it runs) brings
    /// Home back when no window is showing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            companionManager.openHomeWindow()
        }
        return true
    }

    /// Closing Home only hides it; Dottie keeps listening from the menu bar
    /// and notch until the user quits (cmd+Q, the Dock menu, the panel's
    /// Quit button, or Force Quit).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// The Dock icon's right-click menu.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let dockMenu = NSMenu()
        let openHomeItem = NSMenuItem(title: "Open Dottie", action: #selector(openHomeFromDockMenu), keyEquivalent: "")
        openHomeItem.target = self
        dockMenu.addItem(openHomeItem)
        let openSettingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettingsFromDockMenu), keyEquivalent: "")
        openSettingsItem.target = self
        dockMenu.addItem(openSettingsItem)
        return dockMenu
    }

    @objc private func openHomeFromDockMenu() {
        openHomeWindow(on: nil)
    }

    @objc private func openSettingsFromDockMenu() {
        openHomeWindow(on: .settings)
    }

    /// Opens Home, on a page when one is given (the menu's Settings…).
    func openHomeWindow(on homeSection: HomeSpaceRootView.HomeSection?) {
        if let homeSection {
            DottieHomeNavigator.shared.requestedSection = homeSection
        }
        companionManager.openHomeWindow()
    }

    /// macOS marks the launch event when it starts an app as a login item.
    private static var wasLaunchedAsLoginItem: Bool {
        guard let launchEvent = NSAppleEventManager.shared().currentAppleEvent else { return false }
        // The Apple Event constants come in as plain integers; the event's
        // fields are four-character codes (UInt32), so convert explicitly.
        return launchEvent.eventID == AEEventID(kAEOpenApplication)
            && launchEvent.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if Self.isHostingUnitTests { return }
        companionManager.stop()
        DottieGameplayRecorder.shared.stopRecording()
    }

    /// Registers the app as a login item so it launches automatically on
    /// startup. Uses SMAppService which shows the app in System Settings >
    /// General > Login Items, letting the user toggle it off if they want.
    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                DottieLog.notice("🎯 Dottie: Registered as login item")
            } catch {
                DottieLog.warning("⚠️ Dottie: Failed to register as login item: \(error)")
            }
        }
    }
}
