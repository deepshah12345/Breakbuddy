//
//  ReminderScheduler.swift
//  BreakBuddy
//
//  Timer-based scheduler. A single cheap "tick" timer compares each reminder's
//  next-fire date with the clock. The clock and system state (idle / Focus) are
//  injected so the logic can be unit tested without waiting for real time.
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

    private var nextFire: [ReminderType: Date] = [:]
    private var appliedConfig: [ReminderType: ReminderConfig] = [:]
    private var lastTick: Date
    private var wasInsideWorkingHours = true

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

        // React to interval / enabled changes made in Settings.
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

    /// Shows a reminder immediately (used by "Remind me now"); does not touch the schedule.
    func remindNow(_ type: ReminderType) {
        onFire?(makeReminder(type))
    }

    /// Postpones one reminder type.
    func snooze(_ type: ReminderType, minutes: Int) {
        nextFire[type] = now().addingTimeInterval(TimeInterval(minutes * 60))
    }

    /// When the given type will next be due (nil if never scheduled).
    func nextFireDate(for type: ReminderType) -> Date? { nextFire[type] }

    /// Restarts every countdown from "now".
    func resetAll() {
        let current = now()
        for type in ReminderType.allCases {
            let config = settings.config(for: type)
            appliedConfig[type] = config
            nextFire[type] = current.addingTimeInterval(interval(of: config))
        }
        lastTick = current
        wasInsideWorkingHours = settings.isWithinWorkingHours(current)
    }

    /// Called after the Mac wakes from sleep.
    /// - A reminder that came due while asleep is shown shortly after waking (one per type,
    ///   never a pile of missed ones).
    /// - A reminder that was not yet due keeps its original time, so time already
    ///   counted before sleeping is not lost.
    func handleWake() {
        let current = now()
        for type in ReminderType.allCases {
            if let due = nextFire[type], due <= current {
                nextFire[type] = current.addingTimeInterval(Constants.wakeGraceDelay)
            }
        }
        lastTick = current
        // Don't let the "working hours just opened" restart wipe out the catch-up above.
        wasInsideWorkingHours = settings.isWithinWorkingHours(current)
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

        // Working hours: do nothing outside them; restart countdowns on entry
        // so there's no reminder the instant the workday begins.
        guard settings.isWithinWorkingHours(current) else {
            wasInsideWorkingHours = false
            return
        }
        if !wasInsideWorkingHours {
            wasInsideWorkingHours = true
            resetAll()
            return
        }

        for type in ReminderType.allCases {
            if let due = nextFire[type], due <= current {
                evaluate(type, at: current)
            }
        }
    }

    // MARK: - Private

    /// Decides what to do with a reminder that is due.
    private func evaluate(_ type: ReminderType, at current: Date) {
        let config = settings.config(for: type)
        let fullInterval = interval(of: config)

        guard config.enabled else {
            nextFire[type] = current.addingTimeInterval(fullInterval)
            return
        }
        // User is away from the keyboard: skip this occurrence.
        if system.idleSeconds > Constants.idleThreshold {
            nextFire[type] = current.addingTimeInterval(fullInterval)
            return
        }
        // Do Not Disturb / Focus: try again shortly rather than skipping a whole interval.
        if settings.respectFocus && system.isFocusModeActive {
            nextFire[type] = current.addingTimeInterval(Constants.focusRetryInterval)
            return
        }

        nextFire[type] = current.addingTimeInterval(fullInterval)
        onFire?(makeReminder(type))
    }

    private func makeReminder(_ type: ReminderType) -> Reminder {
        Reminder(type: type, message: settings.randomMessage(for: type), date: now())
    }

    private func interval(of config: ReminderConfig) -> TimeInterval {
        TimeInterval(max(1, config.intervalMinutes) * 60)
    }

    /// Restart a countdown only when its interval/enabled flag actually changed.
    private func settingsDidChange() {
        let current = now()
        for type in ReminderType.allCases {
            let config = settings.config(for: type)
            if let old = appliedConfig[type],
               old.intervalMinutes == config.intervalMinutes, old.enabled == config.enabled {
                appliedConfig[type] = config // e.g. only the messages changed
                continue
            }
            appliedConfig[type] = config
            nextFire[type] = current.addingTimeInterval(interval(of: config))
        }
    }
}
