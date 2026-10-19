//
//  ReminderScheduler.swift
//  BreakBuddy
//
//  Timer-based scheduler. A single cheap "tick" timer compares each reminder's
//  next-fire date with the clock. The clock and system state (idle / Focus) are
//  injected so the logic can be unit tested without waiting for real time.
//
//  Reminders are identified by their `ReminderDefinition.id`, so the built-in
//  Water / Break reminders and any number of custom ones are handled identically.
//

import Foundation
import AppKit
import Combine

/// Abstraction over things the scheduler asks the OS about.
protocol SystemStateProviding {
    /// Seconds since the last keyboard/mouse input.
    var idleSeconds: TimeInterval { get }
    /// True when Do Not Disturb / a Focus mode is active (best effort).
    var isFocusModeActive: Bool { get }
}

final class ReminderScheduler: ObservableObject {

    enum Constants {
        /// How often we compare the clock with next-fire dates.
        static let tickInterval: TimeInterval = 5
        /// Idle longer than this => user is away, skip the reminder.
        static let idleThreshold: TimeInterval = 5 * 60
        /// When Focus is on we look again after this long.
        static let focusRetryInterval: TimeInterval = 5 * 60
        /// A gap between ticks longer than this means the Mac slept.
        static let sleepGapThreshold: TimeInterval = 60
        /// A reminder that came due while the Mac slept shows this long after waking.
        static let wakeGraceDelay: TimeInterval = 60
    }

    @Published private(set) var isPaused = false

    /// Called when a reminder should be displayed.
    var onFire: ((Reminder) -> Void)?

    private let settings: AppSettings
    private let system: SystemStateProviding
    private let now: () -> Date

    private var nextFire: [String: Date] = [:]
    private var appliedConfig: [String: ReminderConfig] = [:]
    private var lastTick: Date
    /// Whether each reminder was inside its active window at the last tick.
    private var wasInside: [String: Bool] = [:]

    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var wakeObservers: [NSObjectProtocol] = []

    init(settings: AppSettings,
         system: SystemStateProviding,
         now: @escaping () -> Date = Date.init) {
        self.settings = settings
        self.system = system
        self.now = now
        self.lastTick = now()
    }

    deinit {
        timer?.invalidate()
        wakeObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    // MARK: - Lifecycle

    /// Starts the tick timer and begins observing settings + sleep/wake.
    func start() {
        resetAll()

        let tickTimer = Timer(timeInterval: Constants.tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tickTimer.tolerance = 1
        RunLoop.main.add(tickTimer, forMode: .common) // keeps ticking while menus are open
        timer = tickTimer

        // React to interval / enabled changes and added / deleted reminders.
        settings.objectWillChange
            .receive(on: DispatchQueue.main) // values are updated by the time we run
            .sink { [weak self] _ in self?.settingsDidChange() }
            .store(in: &cancellables)

        // After sleep, keep countdowns that still have time left and give overdue ones a short grace delay.
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification
        ]
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.handleWake()
            }
            wakeObservers.append(token)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Pause / resume

    func pause() { isPaused = true }

    func resume() {
        isPaused = false
        resetAll() // fresh countdowns, no catch-up reminders
    }

    func togglePause() { isPaused ? resume() : pause() }

    // MARK: - Public actions

    /// Shows a reminder immediately (used by "Remind me now" and Preview); does not touch the schedule.
    func remindNow(_ reminderID: String) {
        guard let reminder = makeReminder(reminderID) else { return }
        onFire?(reminder)
    }

    /// Postpones one reminder.
    func snooze(_ reminderID: String, minutes: Int) {
        nextFire[reminderID] = now().addingTimeInterval(TimeInterval(minutes * 60))
    }

    /// When the given reminder will next be due (nil if never scheduled).
    func nextFireDate(for reminderID: String) -> Date? { nextFire[reminderID] }

    /// Restarts every countdown from "now".
    func resetAll() {
        let current = now()
        nextFire.removeAll()
        appliedConfig.removeAll()
        for reminder in settings.reminders {
            appliedConfig[reminder.id] = reminder.config
            nextFire[reminder.id] = current.addingTimeInterval(interval(of: reminder.config))
        }
        lastTick = current
        wasInside = Dictionary(uniqueKeysWithValues: settings.reminders.map {
            ($0.id, settings.isReminderActive($0.id, at: current))
        })
    }

    /// Called after the Mac wakes from sleep.
    /// - A reminder that came due while asleep is shown shortly after waking (one per reminder,
    ///   never a pile of missed ones).
    /// - A reminder that was not yet due keeps its original time, so time already
    ///   counted before sleeping is not lost.
    func handleWake() {
        let current = now()
        for (id, due) in nextFire where due <= current {
            nextFire[id] = current.addingTimeInterval(Constants.wakeGraceDelay)
        }
        lastTick = current
        // Don't let the "window just opened" restart wipe out the catch-up above.
        wasInside = Dictionary(uniqueKeysWithValues: settings.reminders.map {
            ($0.id, settings.isReminderActive($0.id, at: current))
        })
    }

    // MARK: - Ticking (internal so tests can drive it directly)

    func tick() {
        let current = now()
        defer { lastTick = current }

        // A long gap between ticks means the machine slept (covers a missed wake notification).
        if current.timeIntervalSince(lastTick) > Constants.sleepGapThreshold {
            handleWake()
            return
        }
        guard !isPaused else { return }

        // Each reminder has its own active window (its own schedule or the global working
        // hours). Outside it we do nothing; when it opens the countdown restarts, so there's
        // no reminder the instant the window begins.
        for reminder in settings.reminders {
            guard settings.isReminderActive(reminder.id, at: current) else {
                wasInside[reminder.id] = false
                continue
            }
            if wasInside[reminder.id] == false {
                wasInside[reminder.id] = true
                nextFire[reminder.id] = current.addingTimeInterval(interval(of: reminder.config))
                continue
            }
            if let due = nextFire[reminder.id], due <= current {
                evaluate(reminder.id, at: current)
            }
        }
    }

    // MARK: - Private

    /// Decides what to do with a reminder that is due.
    private func evaluate(_ id: String, at current: Date) {
        let config = settings.config(for: id)
        let fullInterval = interval(of: config)

        guard config.enabled else {
            nextFire[id] = current.addingTimeInterval(fullInterval)
            return
        }
        // User is away from the keyboard: skip this occurrence.
        if system.idleSeconds > Constants.idleThreshold {
            nextFire[id] = current.addingTimeInterval(fullInterval)
            return
        }
        // Do Not Disturb / Focus: try again shortly rather than skipping a whole interval.
        if settings.respectFocus && system.isFocusModeActive {
            nextFire[id] = current.addingTimeInterval(Constants.focusRetryInterval)
            return
        }

        nextFire[id] = current.addingTimeInterval(fullInterval)
        if let reminder = makeReminder(id) {
            onFire?(reminder)
        }
    }

    private func makeReminder(_ id: String) -> Reminder? {
        guard let definition = settings.reminder(id: id) else { return nil }
        return Reminder(reminderID: id,
                        name: definition.name,
                        symbolName: definition.symbolName,
                        message: settings.randomMessage(for: id),
                        date: now())
    }

    private func interval(of config: ReminderConfig) -> TimeInterval {
        TimeInterval(max(1, config.intervalMinutes) * 60)
    }

    /// Keeps the schedule in step with Settings:
    /// - new reminders start their countdown now
    /// - deleted reminders are forgotten
    /// - a changed interval / enabled flag restarts that reminder's countdown
    /// - changes to messages, names or icons leave countdowns alone
    private func settingsDidChange() {
        let current = now()
        let liveIDs = Set(settings.reminders.map(\.id))

        for id in nextFire.keys where !liveIDs.contains(id) {
            nextFire[id] = nil
            appliedConfig[id] = nil
            wasInside[id] = nil
        }

        for reminder in settings.reminders {
            let config = reminder.config
            if let old = appliedConfig[reminder.id],
               nextFire[reminder.id] != nil,
               old.intervalMinutes == config.intervalMinutes, old.enabled == config.enabled {
                appliedConfig[reminder.id] = config
                continue
            }
            appliedConfig[reminder.id] = config
            nextFire[reminder.id] = current.addingTimeInterval(interval(of: config))
        }
    }
}
