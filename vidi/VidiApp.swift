//
//  VidiApp.swift
//  vidi
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import ServiceManagement
import SwiftUI

@main
struct VidiApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the menu bar panel managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    // Lazy so that `VidiRegisteredDefaults.register()` (below) runs BEFORE this is
    // first accessed — constructing CompanionManager builds BuddyDictationManager,
    // which resolves the STT provider from UserDefaults in its initializer. A
    // stored-property initializer would run before the delegate body, seeding the
    // defaults too late to pin `vidiTranscriptionProvider=grok` over the plist
    // `apple` fallback after a settings reset.
    private lazy var companionManager = CompanionManager()
    private var handsControlServer: HandsControlServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🎯 Vidi: Starting...")
        print("🎯 Vidi: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        // Pin the load-bearing voice-stack prefs so a `defaults delete` can't
        // silently revert STT to Apple Speech. Must run before companionManager
        // is first accessed (see the lazy declaration above).
        VidiRegisteredDefaults.register()

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        VidiAnalytics.configure()
        VidiAnalytics.trackAppOpened()

        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        companionManager.start()

        // GUI actuation ("Hands"): a loopback, token-authed control server that
        // lets Vidi physically click and type (the "never touch me again"
        // capability). Requires the Accessibility permission — prompt for it
        // once here; macOS remembers the grant across launches.
        let handsServer = HandsControlServer(
            port: VidiConfig.handsControlPort,
            sharedToken: VidiConfig.handsControlToken
        )
        // Lets proactive speak/chime actions reach the companion's mouth.
        handsServer.companionManager = companionManager
        // VP Lab bisect gate (CoreAudio dig, Day 1): when the hands-server row is
        // disabled, never start the loopback NWListener (a candidate main-thread
        // contributor to the VP death). Genuinely not-started, not merely hidden.
        var handsServerDisabledByVPLab = false
        #if DEBUG
        handsServerDisabledByVPLab = VPLab.isDisabled(.handsControlServer)
        if handsServerDisabledByVPLab {
            vlog("🧪 VPLab: hands control server DISABLED — not starting listener")
        }
        #endif
        if !handsServerDisabledByVPLab {
            handsServer.start()
        }
        handsControlServer = handsServer
        AccessibilityGrounding.promptForTrustIfNeeded()
        // Auto-open the panel if the user still needs to do something:
        // either they haven't onboarded yet, or permissions were revoked.
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            menuBarPanelManager?.showPanelOnLaunch()
        }
        registerAsLoginItemIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }

    /// Registers the app as a login item so it launches automatically on
    /// startup. Uses SMAppService which shows the app in System Settings >
    /// General > Login Items, letting the user toggle it off if they want.
    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                print("🎯 Vidi: Registered as login item")
            } catch {
                print("⚠️ Vidi: Failed to register as login item: \(error)")
            }
        }
    }
}
