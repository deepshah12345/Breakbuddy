//
//  ReminderPanelController.swift
//  BreakBuddy
//
//  Owns the transparent, borderless, always-on-top NSPanel that shows a
//  reminder. Responsibilities:
//    - queueing: never two popups at once
//    - placing the panel in the configured corner of the main screen
//    - visible on every Space and over full-screen apps, without stealing focus
//    - click-through everywhere except the speech bubble
//    - the ~8 second auto-dismiss and the slide-out
//

import AppKit
import SwiftUI

// MARK: - Panel + hosting view

/// A panel that can never become key/main, so it can't take focus from other apps.
private final class ReminderPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that handles the very first click, even though the panel's app
/// is not active (required for buttons in a non-activating panel).
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Controller

final class ReminderPanelController {

    /// How long the popup stays before sliding away on its own.
    static let displayDuration: TimeInterval = 8
    private static let slideOutDuration: TimeInterval = 0.6
    private static let gapBetweenReminders: TimeInterval = 0.3

    /// Called when the user taps "Snooze".
    var onSnooze: ((ReminderType, Int) -> Void)?

    private let settings: AppSettings
    private let characters: CharacterStore

    private var queue: [Reminder] = []
    private var current: Reminder?
    private var isDismissing = false

    private var panel: ReminderPanel?
    private var model: ReminderViewModel?
    private var dismissTimer: Timer?
    private var mouseTimer: Timer?

    init(settings: AppSettings, characters: CharacterStore) {
        self.settings = settings
        self.characters = characters
    }

    // MARK: Public

    /// Shows the reminder now, or queues it behind the one on screen.
    func enqueue(_ reminder: Reminder) {
        // Don't stack duplicates of the same type (on screen or already waiting).
        if current?.type == reminder.type || queue.contains(where: { $0.type == reminder.type }) {
            return
        }
        queue.append(reminder)
        presentNextIfNeeded()
    }

    /// Slides the current popup away. `snooze` additionally postpones that reminder type.
    func dismiss(snooze: Bool) {
        guard let reminder = current, !isDismissing else { return }
        isDismissing = true

        dismissTimer?.invalidate()
        dismissTimer = nil
        mouseTimer?.invalidate()
        mouseTimer = nil

        if snooze { onSnooze?(reminder.type, AppSettings.snoozeMinutes) }

        model?.stop()                      // plays the slide-out animation
        panel?.ignoresMouseEvents = true   // can't be clicked while leaving

        let closing = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.slideOutDuration) { [weak self] in
            closing?.orderOut(nil)
            guard let self = self else { return }
            self.panel = nil
            self.model = nil
            self.current = nil
            self.isDismissing = false
            // Small pause so consecutive popups don't feel glued together.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.gapBetweenReminders) { [weak self] in
                self?.presentNextIfNeeded()
            }
        }
    }

    // MARK: Presenting

    private func presentNextIfNeeded() {
        guard current == nil, !queue.isEmpty else { return }
        present(queue.removeFirst())
    }

    private func present(_ reminder: Reminder) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        current = reminder
        isDismissing = false

        let position = settings.reminderPosition
        let model = ReminderViewModel(reminder: reminder, characters: characters,
                                      themeColor: settings.themeColor, position: position)
        self.model = model

        let frame = ReminderLayout.panelFrame(in: screen.visibleFrame, position: position)

        let panel = makePanel(frame: frame)
        let root = ReminderView(
            model: model,
            onDone: { [weak self] in self?.dismiss(snooze: false) },
            onSnooze: { [weak self] in self?.dismiss(snooze: true) }
        )
        model.bubbleSize = NSHostingView(rootView: root.bubbleForMeasuring).fittingSize
        panel.contentView = FirstMouseHostingView(rootView: root)
        panel.setFrame(frame, display: false)
        self.panel = panel

        // orderFrontRegardless shows the panel without activating BreakBuddy.
        panel.orderFrontRegardless()

        if settings.soundEnabled {
            NSSound(named: NSSound.Name("Glass"))?.play()
        }

        // Start the animation on the next run-loop turn so SwiftUI has rendered the
        // off-screen starting state first (otherwise there would be nothing to animate).
        DispatchQueue.main.async { model.start() }

        // "Keep on screen until I tap Done" reminders skip the auto-dismiss timer.
        if !settings.config(for: reminder.type).stayUntilDone {
            startDismissTimer(after: Self.displayDuration)
        }
        startMouseTracking()
    }

    private func makePanel(frame: NSRect) -> ReminderPanel {
        let panel = ReminderPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.level = .statusBar                 // above normal windows
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true     // hover highlight on the buttons
        // Show on every Space and above full-screen apps.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Start click-through; mouse tracking turns this off only over the bubble.
        panel.ignoresMouseEvents = true
        return panel
    }

    // MARK: Timers

    private func startDismissTimer(after interval: TimeInterval) {
        dismissTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            // Don't pull the bubble away while the pointer is on it.
            if self.model?.isHovering == true {
                self.startDismissTimer(after: 2)
            } else {
                self.dismiss(snooze: false)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dismissTimer = timer
    }

    /// Polls the pointer position ~20x/second. The panel ignores mouse events (so
    /// clicks fall through to apps underneath) except while the pointer is over the
    /// speech bubble. Reading NSEvent.mouseLocation needs no special permission.
    private func startMouseTracking() {
        mouseTimer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.updateMouseTransparency()
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    private func updateMouseTransparency() {
        guard let panel = panel, let model = model, !isDismissing else { return }
        let rect = model.interactiveRect
        guard rect != .zero else {
            panel.ignoresMouseEvents = true
            return
        }
        // Convert the bubble rect (top-left origin, panel space) to screen coordinates (bottom-left origin).
        let screenRect = CGRect(
            x: panel.frame.minX + rect.minX,
            y: panel.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
        let inside = screenRect.contains(NSEvent.mouseLocation)

        model.isHovering = inside
        if panel.ignoresMouseEvents == inside {
            panel.ignoresMouseEvents = !inside
        }
    }
}
