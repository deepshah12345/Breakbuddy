//
//  ReminderSchedulerTests.swift
//  Add to a "Unit Testing Bundle" target (File > New > Target > Unit Testing Bundle,
//  host application = BreakBuddy), then run with Cmd+U.
//

import XCTest
@testable import BreakBuddy

/// A class so a test can change idle time after the scheduler has been created.
private final class FakeSystem: SystemStateProviding {
    var idleSeconds: TimeInterval = 0
    var isFocusModeActive = false
}

final class ReminderSchedulerTests: XCTestCase {

    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var fired: [Reminder] = []

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "BreakBuddyTests-\(UUID().uuidString)") ?? .standard
    }

    private func makeScheduler(system: FakeSystem = FakeSystem()) -> (ReminderScheduler, AppSettings) {
        let settings = AppSettings(defaults: makeDefaults())
        let scheduler = ReminderScheduler(settings: settings, system: system, now: { [unowned self] in self.clock })
        scheduler.onFire = { [unowned self] in self.fired.append($0) }
        scheduler.resetAll()
        return (scheduler, settings)
    }

    private func advance(_ seconds: TimeInterval, scheduler: ReminderScheduler) {
        // Tick in small steps like the real timer does (avoids tripping the sleep detector).
        var remaining = seconds
        while remaining > 0 {
            let step = min(5, remaining)
            clock = clock.addingTimeInterval(step)
            scheduler.tick()
            remaining -= step
        }
    }

    // MARK: Built-in reminders

    func testWaterFiresAfterInterval() {
        let (scheduler, _) = makeScheduler()
        advance(44 * 60, scheduler: scheduler)
        XCTAssertTrue(fired.isEmpty)
        advance(60, scheduler: scheduler)
        XCTAssertEqual(fired.map(\.reminderID), [BuiltInReminder.water])
    }

    // MARK: Away rule (countdowns freeze while away)

    func testTimeAsleepDoesNotCount() {
        let (scheduler, _) = makeScheduler()
        clock = clock.addingTimeInterval(8 * 3600) // Mac slept for 8 hours
        scheduler.tick()
        advance(60, scheduler: scheduler)
        XCTAssertTrue(fired.isEmpty) // no catch-up popup right after waking
        advance(43 * 60, scheduler: scheduler)
        XCTAssertTrue(fired.isEmpty) // 44 of 45 minutes have been counted
        advance(2 * 60, scheduler: scheduler)
        XCTAssertEqual(fired.map(\.reminderID), [BuiltInReminder.water]) // continues where it stopped
    }

    func testSleepKeepsTimeAlreadyCounted() {
        let (scheduler, _) = makeScheduler()
        let due = scheduler.nextFireDate(for: BuiltInReminder.water)
        clock = clock.addingTimeInterval(30 * 60) // slept right away for 30 minutes
        scheduler.handleWake()
        XCTAssertEqual(scheduler.nextFireDate(for: BuiltInReminder.water), due?.addingTimeInterval(30 * 60))
    }

    func testPausedDoesNotFire() {
        let (scheduler, _) = makeScheduler()
        scheduler.pause()
        advance(2 * 3600, scheduler: scheduler)
        XCTAssertTrue(fired.isEmpty)
    }

    func testIdleUserFreezesCountdownAndResumesOnReturn() {
        let system = FakeSystem()
        system.idleSeconds = 600
        let (scheduler, _) = makeScheduler(system: system)
        advance(3 * 3600, scheduler: scheduler)
        XCTAssertTrue(fired.isEmpty) // nothing fires while away, nothing piles up

        system.idleSeconds = 0       // user is back
        advance(60 * 60, scheduler: scheduler)
        XCTAssertEqual(fired.filter { $0.reminderID == BuiltInReminder.water }.count, 1)
    }

    func testDisplayOffAndLockedFreezeCountdowns() {
        let (scheduler, _) = makeScheduler()
        scheduler.displayAsleep = true
        advance(2 * 3600, scheduler: scheduler)
        XCTAssertTrue(fired.isEmpty)
        scheduler.displayAsleep = false

        scheduler.screenLocked = true
        advance(2 * 3600, scheduler: scheduler)
        XCTAssertTrue(fired.isEmpty)
        scheduler.screenLocked = false

        advance(44 * 60, scheduler: scheduler)
        XCTAssertTrue(fired.isEmpty)
        advance(2 * 60, scheduler: scheduler)
        XCTAssertEqual(fired.first?.reminderID, BuiltInReminder.water)
    }

    // MARK: Keep on screen until Done

    private func makeStayUntilDone() -> (ReminderScheduler, AppSettings) {
        let (scheduler, settings) = makeScheduler()
        var config = settings.config(for: BuiltInReminder.water)
        config.stayUntilDone = true
        settings.setConfig(config, for: BuiltInReminder.water)
        scheduler.resetAll()
        return (scheduler, settings)
    }

    private func waterCount() -> Int { fired.filter { $0.reminderID == BuiltInReminder.water }.count }

    func testStayUntilDoneCountdownStartsAfterDone() {
        let (scheduler, _) = makeStayUntilDone()
        advance(46 * 60, scheduler: scheduler)
        XCTAssertEqual(waterCount(), 1)

        advance(3 * 3600, scheduler: scheduler) // popup ignored for 3 hours
        XCTAssertEqual(waterCount(), 1)         // no second popup, countdown not running

        scheduler.reminderCompleted(BuiltInReminder.water)
        advance(44 * 60, scheduler: scheduler)
        XCTAssertEqual(waterCount(), 1)
        advance(2 * 60, scheduler: scheduler)   // full interval after Done
        XCTAssertEqual(waterCount(), 2)
    }

    func testStayUntilDoneSnoozeComesBackThenWaitsForDone() {
        let (scheduler, _) = makeStayUntilDone()
        advance(46 * 60, scheduler: scheduler)
        XCTAssertEqual(waterCount(), 1)

        scheduler.snooze(BuiltInReminder.water, minutes: 10)
        advance(9 * 60, scheduler: scheduler)
        XCTAssertEqual(waterCount(), 1)
        advance(2 * 60, scheduler: scheduler)   // back after 10 minutes
        XCTAssertEqual(waterCount(), 2)

        advance(3 * 3600, scheduler: scheduler) // still waiting for Done
        XCTAssertEqual(waterCount(), 2)

        scheduler.reminderCompleted(BuiltInReminder.water)
        advance(46 * 60, scheduler: scheduler)
        XCTAssertEqual(waterCount(), 3)
    }

    func testDoneDoesNothingForAutoDismissReminders() {
        let (scheduler, _) = makeScheduler()
        let due = scheduler.nextFireDate(for: BuiltInReminder.water)
        scheduler.reminderCompleted(BuiltInReminder.water)
        XCTAssertEqual(scheduler.nextFireDate(for: BuiltInReminder.water), due) // countdown unchanged
    }

    func testAutoDismissReminderRestartsCountdownWhenShown() {
        let (scheduler, _) = makeScheduler()
        advance(46 * 60, scheduler: scheduler)
        XCTAssertEqual(waterCount(), 1)
        advance(43 * 60, scheduler: scheduler)  // next one 45 minutes after the first
        XCTAssertEqual(waterCount(), 1)
        advance(2 * 60, scheduler: scheduler)
        XCTAssertEqual(waterCount(), 2)
    }

    func testSnoozeMovesNextFire() {
        let (scheduler, _) = makeScheduler()
        scheduler.snooze(BuiltInReminder.water, minutes: 10)
        advance(9 * 60, scheduler: scheduler)
        XCTAssertTrue(fired.isEmpty)
        advance(90, scheduler: scheduler)
        XCTAssertEqual(fired.first?.reminderID, BuiltInReminder.water)
    }

    func testDisabledReminderNeverFires() {
        let (scheduler, settings) = makeScheduler()
        var config = settings.config(for: BuiltInReminder.water)
        config.enabled = false
        settings.setConfig(config, for: BuiltInReminder.water)
        advance(50 * 60, scheduler: scheduler)
        XCTAssertFalse(fired.contains { $0.reminderID == BuiltInReminder.water })
    }

    // MARK: Custom reminders

    func testCustomReminderFiresOnItsOwnInterval() {
        let (scheduler, settings) = makeScheduler()
        let id = settings.addReminder(name: "Stretch", symbolName: "figure.walk")
        var config = settings.config(for: id)
        config.intervalMinutes = 10
        config.messages = ["Stretch time!"]
        settings.setConfig(config, for: id)
        scheduler.resetAll() // the app does this via the settings observer

        advance(9 * 60, scheduler: scheduler)
        XCTAssertTrue(fired.isEmpty)
        advance(90, scheduler: scheduler)

        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(fired.first?.reminderID, id)
        XCTAssertEqual(fired.first?.name, "Stretch")
        XCTAssertEqual(fired.first?.message, "Stretch time!")
    }

    func testDeletedCustomReminderStopsFiring() {
        let (scheduler, settings) = makeScheduler()
        let id = settings.addReminder(name: "Pills")
        var config = settings.config(for: id)
        config.intervalMinutes = 5
        settings.setConfig(config, for: id)
        scheduler.resetAll()

        settings.deleteReminder(id)
        advance(10 * 60, scheduler: scheduler)
        XCTAssertFalse(fired.contains { $0.reminderID == id })
    }

    func testBuiltInRemindersCannotBeDeleted() {
        let settings = AppSettings(defaults: makeDefaults())
        settings.deleteReminder(BuiltInReminder.water)
        settings.deleteReminder(BuiltInReminder.breakTime)
        XCTAssertEqual(settings.reminders.map(\.id), BuiltInReminder.ids)
    }

    // MARK: Per-reminder schedules

    /// Minutes since midnight of the fake clock, in the local time zone.
    private var clockMinutes: Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: clock)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    private func wrap(_ minutes: Int) -> Int { ((minutes % 1440) + 1440) % 1440 }

    func testOwnScheduleOutsideItsWindowDoesNotFire() {
        let (scheduler, settings) = makeScheduler()
        var config = settings.config(for: BuiltInReminder.water)
        config.useOwnSchedule = true
        config.scheduleDays = [1, 2, 3, 4, 5, 6, 7]
        config.scheduleStartMinutes = wrap(clockMinutes + 120) // window opens in 2 hours
        config.scheduleEndMinutes = wrap(clockMinutes + 180)
        settings.setConfig(config, for: BuiltInReminder.water)
        scheduler.resetAll()

        advance(50 * 60, scheduler: scheduler)
        XCTAssertFalse(fired.contains { $0.reminderID == BuiltInReminder.water })
    }

    func testOwnScheduleInsideItsWindowFires() {
        let (scheduler, settings) = makeScheduler()
        var config = settings.config(for: BuiltInReminder.water)
        config.useOwnSchedule = true
        config.scheduleDays = [1, 2, 3, 4, 5, 6, 7]
        config.scheduleStartMinutes = wrap(clockMinutes - 10)
        config.scheduleEndMinutes = wrap(clockMinutes + 600)
        settings.setConfig(config, for: BuiltInReminder.water)
        scheduler.resetAll()

        advance(46 * 60, scheduler: scheduler)
        XCTAssertTrue(fired.contains { $0.reminderID == BuiltInReminder.water })
    }

    func testOwnScheduleWithNoDaysNeverFires() {
        let (scheduler, settings) = makeScheduler()
        var config = settings.config(for: BuiltInReminder.water)
        config.useOwnSchedule = true
        config.scheduleDays = []
        settings.setConfig(config, for: BuiltInReminder.water)
        scheduler.resetAll()

        advance(50 * 60, scheduler: scheduler)
        XCTAssertFalse(fired.contains { $0.reminderID == BuiltInReminder.water })
    }

    func testReminderWithoutOwnScheduleFollowsGlobalWorkingHours() {
        let (scheduler, settings) = makeScheduler()
        settings.workingHoursEnabled = true
        settings.workDays = ReminderConfig.allDayNumbers
        settings.workStartMinutes = wrap(clockMinutes + 120) // global window is closed right now
        settings.workEndMinutes = wrap(clockMinutes + 180)
        scheduler.resetAll()

        advance(50 * 60, scheduler: scheduler)
        XCTAssertTrue(fired.isEmpty)
    }

    func testLegacyWeekdaysOnlySwitchIsMigratedToWorkDays() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: "weekdaysOnly")
        XCTAssertEqual(AppSettings(defaults: defaults).workDays, [1, 2, 3, 4, 5, 6, 7])

        let fresh = AppSettings(defaults: makeDefaults())
        XCTAssertEqual(fresh.workDays, [2, 3, 4, 5, 6])
    }

    func testOldSavedConfigWithoutScheduleFieldsStillLoads() throws {
        let json = #"{"enabled":true,"intervalMinutes":30,"messages":["Hi"]}"#
        let config = try JSONDecoder().decode(ReminderConfig.self, from: Data(json.utf8))
        XCTAssertFalse(config.useOwnSchedule)
        XCTAssertEqual(config.scheduleDays, [2, 3, 4, 5, 6])
        XCTAssertEqual(config.intervalMinutes, 30)
    }

    // MARK: Persistence and migration

    func testCustomRemindersPersistAcrossLaunches() {
        let defaults = makeDefaults()
        let first = AppSettings(defaults: defaults)
        let id = first.addReminder(name: "Eye drops", symbolName: "eye")

        let second = AppSettings(defaults: defaults)
        XCTAssertEqual(second.reminder(id: id)?.name, "Eye drops")
        XCTAssertEqual(second.reminder(id: id)?.symbolName, "eye")
        // Built-ins always come first.
        XCTAssertEqual(second.reminders.prefix(2).map(\.id), BuiltInReminder.ids)
    }

    func testLegacyBuiltInSettingsAreMigrated() throws {
        let defaults = makeDefaults()
        let legacy = ReminderConfig(enabled: false, intervalMinutes: 25, messages: ["Old water message"])
        defaults.set(try JSONEncoder().encode(legacy), forKey: "config.water")

        let settings = AppSettings(defaults: defaults)
        let water = settings.config(for: BuiltInReminder.water)
        XCTAssertEqual(water.intervalMinutes, 25)
        XCTAssertFalse(water.enabled)
        XCTAssertEqual(water.messages, ["Old water message"])
        // The break reminder had no saved settings, so it keeps its defaults.
        XCTAssertEqual(settings.config(for: BuiltInReminder.breakTime).intervalMinutes, 60)
    }
}
