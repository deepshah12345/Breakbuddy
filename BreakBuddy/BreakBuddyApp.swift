//
//  BreakBuddyApp.swift
//  BreakBuddy
//
//  App entry point. The app has no windows of its own at launch (it lives in the
//  menu bar), so the SwiftUI scene is empty and AppDelegate wires everything up.
//

import SwiftUI
import AppKit

@main
struct BreakBuddyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // SwiftUI requires at least one scene. Our real Settings window is
        // SettingsWindowController, which works properly for menu bar apps.
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: AppSettings?
    private var characters: CharacterStore?
    private var scheduler: ReminderScheduler?
    private var panelController: ReminderPanelController?
    private var settingsWindow: SettingsWindowController?
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt and braces: Info.plist already sets LSUIElement, this guarantees no Dock icon.
        NSApp.setActivationPolicy(.accessory)

        let settings = AppSettings()
        let characters = CharacterStore()
        let scheduler = ReminderScheduler(settings: settings, system: SystemState())
        let panelController = ReminderPanelController(settings: settings, characters: characters)

        // Scheduler -> popup (the panel queues if one is already showing).
        scheduler.onFire = { [weak panelController] reminder in
            panelController?.enqueue(reminder)
        }
        // Snooze button -> scheduler.
        panelController.onSnooze = { [weak scheduler] reminderID, minutes in
            scheduler?.snooze(reminderID, minutes: minutes)
        }
        // Done button -> scheduler (starts the next countdown for "keep until Done" reminders).
        panelController.onDone = { [weak scheduler] reminderID in
            scheduler?.reminderCompleted(reminderID)
        }

        let settingsWindow = SettingsWindowController(
            settings: settings,
            characters: characters,
            onPreview: { [weak scheduler] reminderID in scheduler?.remindNow(reminderID) }
        )
        let menuBar = MenuBarController(
            scheduler: scheduler,
            settings: settings,
            onOpenSettings: { [weak settingsWindow] in settingsWindow?.show() }
        )

        scheduler.start()

        // Keep strong references alive for the app's lifetime.
        self.settings = settings
        self.characters = characters
        self.scheduler = scheduler
        self.panelController = panelController
        self.settingsWindow = settingsWindow
        self.menuBar = menuBar
    }

    /// Closing the Settings window must not quit a menu bar app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
