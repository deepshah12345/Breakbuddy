//
//  MenuBarController.swift
//  BreakBuddy
//
//  The menu bar icon and its menu: Pause/Resume, Remind me now, Settings, Quit.
//  Also shows when each reminder is next due.
//

import AppKit
import Combine

final class MenuBarController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let scheduler: ReminderScheduler
    private let onOpenSettings: () -> Void

    private let pauseItem = NSMenuItem(title: "Pause", action: nil, keyEquivalent: "")
    private let infoItems: [ReminderType: NSMenuItem]
    private var cancellables = Set<AnyCancellable>()
    private var testIndex = 0

    init(scheduler: ReminderScheduler, onOpenSettings: @escaping () -> Void) {
        self.scheduler = scheduler
        self.onOpenSettings = onOpenSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        var items: [ReminderType: NSMenuItem] = [:]
        for type in ReminderType.allCases {
            let item = NSMenuItem(title: type.title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            items[type] = item
        }
        self.infoItems = items
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

        let header = NSMenuItem(title: "BreakBuddy", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for type in ReminderType.allCases {
            if let item = infoItems[type] { menu.addItem(item) }
        }
        menu.addItem(.separator())

        pauseItem.target = self
        pauseItem.action = #selector(togglePause)
        pauseItem.isEnabled = true
        menu.addItem(pauseItem)

        let remind = NSMenuItem(title: "Remind me now", action: #selector(remindNow), keyEquivalent: "r")
        remind.target = self
        menu.addItem(remind)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit BreakBuddy", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    /// Refresh the dynamic titles each time the menu is about to open.
    func menuNeedsUpdate(_ menu: NSMenu) {
        pauseItem.title = scheduler.isPaused ? "Resume" : "Pause"
        for type in ReminderType.allCases {
            infoItems[type]?.title = infoText(for: type)
        }
    }

    private func infoText(for type: ReminderType) -> String {
        if scheduler.isPaused { return "\(type.title): paused" }
        guard let due = scheduler.nextFireDate(for: type) else { return "\(type.title): not scheduled" }
        let minutes = max(0, Int((due.timeIntervalSinceNow / 60).rounded(.up)))
        return "\(type.title): in \(minutes) min"
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

    /// Alternates between a water and a break test reminder.
    @objc private func remindNow() {
        let types = ReminderType.allCases
        scheduler.remindNow(types[testIndex % types.count])
        testIndex += 1
    }

    @objc private func openSettings() { onOpenSettings() }

    @objc private func quit() { NSApp.terminate(nil) }
}
