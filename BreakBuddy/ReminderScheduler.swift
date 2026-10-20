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
        /// No keyboard / mouse for longer than this => the user is away.
        static let idleThreshold: TimeInterval = 5 * 60
        /// When Focus is on we look again after this long.
        static let focusRetryInterval: TimeInterval = 5 * 60
        /// A gap between ticks longer than this means the Mac slept.
        static let sleepGapThreshold: TimeInterval = 60
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
    private var distributedObservers: [NSObjectProtocol] = []

    /// True while the display is off (the Mac itself may still be running).
    var displayAsleep = false
    /// True while the screen is locked or another user's session is in front.
    var screenLocked = false
    /// Whether the user was away at the previous tick.
    private var wasAway = false

    /// Reminders whose popup is on screen waiting for "Done" (only for "keep on screen until
    /// I tap Done"). Their countdown does not run; it starts after Done is tapped.
    private var awaitingDone: Set<String> = []

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
        distributedObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
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

        // Waking from sleep: the time spent asleep must not count (see handleWake).
        let center = NSWorkspace.shared.notificationCenter
        let wakeNames: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification
        ]
        for name in wakeNames {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.handleWake()
            }
            wakeObservers.append(token)
        }

        // Track "nobody can see the screen" so countdowns freeze while the display is off or locked.
        func track(_ name: Notification.Name, center: NotificationCenter,
                   _ update: @escaping (ReminderScheduler) -> Void) -> NSObjectProtocol {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                if let self = self { update(self) }
            }
        }
        wakeObservers.append(track(NSWorkspace.screensDidSleepNotification, center: center) { $0.displayAsleep = true })
        wakeObservers.append(track(NSWorkspace.screensDidWakeNotification, center: center) { $0.displayAsleep = false })
        wakeObservers.append(track(NSWorkspace.sessionDidResignActiveNotification, center: center) { $0.screenLocked = true })
        wakeObservers.append(track(NSWorkspace.sessionDidBecomeActiveNotification, center: center) { $0.screenLocked = false })

        // The lock screen has no public API; these distributed notifications are widely used for it.
        let distributed = DistributedNotificationCenter.default()
        distributedObservers.append(track(Notification.Name("com.apple.screenIsLocked"), center: distributed) { $0.screenLocked = true })
        distributedObservers.append(track(Notification.Name("com.apple.screenIsUnlocked"), center: distributed) { $0.screenLocked = false })
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
    /// The popup comes back after `minutes`; once it is shown again (and, for "keep until Done"
    /// reminders, once the user taps Done) the normal interval starts.
    func snooze(_ reminderID: String, minutes: Int) {
        awaitingDone.remove(reminderID)
        nextFire[reminderID] = now().addingTimeInterval(TimeInterval(minutes * 60))
    }

    /// The user tapped Done. For a "keep on screen until I tap Done" reminder this starts the
    /// next countdown; for any other reminder it does nothing (its countdown already runs).
    func reminderCompleted(_ reminderID: String) {
        guard awaitingDone.remove(reminderID) != nil,
              let definition = settings.reminder(id: reminderID) else { return }
        nextFire[reminderID] = now().addingTimeInterval(interval(of: definition.config))
    }

    /// When the given reminder will next be due (nil if never scheduled).
    func nextFireDate(for reminderID: String) -> Date? { nextFire[reminderID] }

    /// Restarts every countdown from "now".
    func resetAll() {
        let current = now()
        nextFire.removeAll()
        appliedConfig.removeAll()
        awaitingDone.removeAll()
        for reminder in settings.reminders {
            appliedConfig[reminder.id] = reminder.config
            nextFire[reminder.id] = current.addingTimeInterval(interval(of: reminder.config))
        }
        lastTick = current
        wasInside = Dictionary(uniqueKeysWithValues: settings.reminders.map {
            ($0.id, settings.isReminderActive($0.id, at: current))
        })
    }

    /// Called after the Mac wakes from sleep (and by the tick when it notices a long gap).
    /// The time spent asleep doesn't count: every countdown is pushed back by it, so each
    /// reminder continues where it stopped. Nothing is shown the moment the Mac wakes.
    func handleWake() {
        let current = now()
        let slept = current.timeIntervalSince(lastTick)
        if slept > 0 { shiftCountdowns(by: slept) }
        lastTick = current
        // Don't let the "window just opened" restart wipe out the countdowns above.
        wasInside = Dictionary(uniqueKeysWithValues: settings.reminders.map {
            ($0.id, settings.isReminderActive($0.id, at: current))
        })
    }

    // MARK: - Ticking (internal so tests can drive it directly)

    func tick() {
        let current = now()
        let elapsed = current.timeIntervalSince(lastTick)
        defer { lastTick = current }

        // A long gap between ticks means the machine slept (covers a missed wake notification).
        if elapsed > Constants.sleepGapThreshold {
            handleWake()
            return
        }
        guard !isPaused else { return }

        // While the user is away every countdown freezes; it continues when they return.
        let away = isUserAway
        let justLeft = away && !wasAway
        wasAway = away
        if away {
            var shift = elapsed
            if justLeft && system.idleSeconds > Constants.idleThreshold {
                // They stopped touching the Mac a few minutes ago; give those minutes back too.
                // Capped so a huge idle time (e.g. the app just launched) can't push things out for hours.
                shift = max(elapsed, min(system.idleSeconds, Constants.idleThreshold + elapsed))
            }
            shiftCountdowns(by: shift)
            return
        }

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
                if awaitingDone.contains(reminder.id) { continue } // popup is waiting for Done
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
        // Do Not Disturb / Focus: try again shortly rather than skipping a whole interval.
        if settings.respectFocus && system.isFocusModeActive {
            nextFire[id] = current.addingTimeInterval(Constants.focusRetryInterval)
            return
        }

        if config.stayUntilDone {
            // Keep-until-Done: the countdown starts only after the user taps Done.
            awaitingDone.insert(id)
            nextFire[id] = nil
        } else {
            nextFire[id] = current.addingTimeInterval(fullInterval)
        }
        if let reminder = makeReminder(id) {
            onFire?(reminder)
        }
    }

    /// True when nobody is likely looking at the screen: no input for a while, display off,
    /// screen locked, or another user's session in front.
    private var isUserAway: Bool {
        system.idleSeconds > Constants.idleThreshold || displayAsleep || screenLocked
    }

    /// Pushes every countdown later by `seconds` (this is how time is "frozen").
    private func shiftCountdowns(by seconds: TimeInterval) {
        guard seconds > 0 else { return }
        nextFire = nextFire.mapValues { $0.addingTimeInterval(seconds) }
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
        awaitingDone.formIntersection(liveIDs)

        for reminder in settings.reminders {
            let config = reminder.config
            if awaitingDone.contains(reminder.id) {
                if config.enabled && config.stayUntilDone {
                    appliedConfig[reminder.id] = config // keep waiting for Done
                    continue
                }
                awaitingDone.remove(reminder.id)        // no longer a keep-until-Done reminder
            }
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
