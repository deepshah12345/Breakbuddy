//
//  MenuBarController.swift
//  BreakBuddy
//
//  The menu bar icon and its menu: Pause/Resume, Remind me now, Settings, Quit.
//  Also lists every reminder (built-in and custom) with when it is next due.
//

import AppKit
import Combine

final class MenuBarController: NSObject, NSMenuDelegate {

    /// Tag put on the per-reminder info rows so they can be rebuilt each time the menu opens.
    private static let infoItemTag = 9001

    private let statusItem: NSStatusItem
    private let scheduler: ReminderScheduler
    private let settings: AppSettings
    private let onOpenSettings: () -> Void

    private let pauseItem = NSMenuItem(title: "Pause", action: nil, keyEquivalent: "")
    private var cancellables = Set<AnyCancellable>()
    private var testIndex = 0

    init(scheduler: ReminderScheduler, settings: AppSettings, onOpenSettings: @escaping () -> Void) {
        self.scheduler = scheduler
        self.settings = settings
        self.onOpenSettings = onOpenSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        buildMenu()
        updateIcon()

        // Swap the icon when pausing/resuming.
        scheduler.$isPaused
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
    }

    // MARK: Menu

    private func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        // The header is followed by one info row per reminder (added in menuNeedsUpdate).
        let header = NSMenuItem(title: "BreakBuddy", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        pauseItem.target = self
        pauseItem.action = #selector(togglePause)
        pauseItem.isEnabled = true
        menu.addItem(pauseItem)

        let remind = NSMenuItem(title: "Remind me now", action: #selector(remindNow), keyEquivalent: "r")
        remind.target = self
        menu.addItem(remind)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quit = NSMenuItem(title: "Quit BreakBuddy", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    /// Refresh the dynamic rows each time the menu is about to open.
    func menuNeedsUpdate(_ menu: NSMenu) {
        pauseItem.title = scheduler.isPaused ? "Resume" : "Pause"

        // Rebuild the reminder rows, because custom reminders can be added or deleted.
        for item in menu.items where item.tag == Self.infoItemTag {
            menu.removeItem(item)
        }
        var insertIndex = 1 // right after the "BreakBuddy" header
        for reminder in settings.reminders {
            let item = NSMenuItem(title: infoText(for: reminder), action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.tag = Self.infoItemTag
            if let image = NSImage(systemSymbolName: reminder.symbolName, accessibilityDescription: reminder.name) {
                item.image = image
            }
            menu.insertItem(item, at: insertIndex)
            insertIndex += 1
        }
    }

    private func infoText(for reminder: ReminderDefinition) -> String {
        if scheduler.isPaused { return "\(reminder.name): paused" }
        if !reminder.config.enabled { return "\(reminder.name): off" }
        guard let due = scheduler.nextFireDate(for: reminder.id) else { return "\(reminder.name): not scheduled" }
        let minutes = max(0, Int((due.timeIntervalSinceNow / 60).rounded(.up)))
        return "\(reminder.name): in \(minutes) min"
    }

    // MARK: Icon

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let symbol = scheduler.isPaused ? "drop" : "drop.fill"
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "BreakBuddy") {
            image.isTemplate = true // adapts to light/dark menu bars
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = "BB"
        }
    }

    // MARK: Actions

    @objc private func togglePause() { scheduler.togglePause() }

    /// Cycles through every reminder, one test popup per click.
    @objc private func remindNow() {
        let reminders = settings.reminders
        guard !reminders.isEmpty else { return }
        scheduler.remindNow(reminders[testIndex % reminders.count].id)
        testIndex += 1
    }

    @objc private func openSettings() { onOpenSettings() }

    @objc private func quit() { NSApp.terminate(nil) }
}
