//
//  ReminderSchedulerTests.swift
//  Add to a "Unit Testing Bundle" target (File > New > Target > Unit Testing Bundle,
//  host application = BreakBuddy), then run with Cmd+U.
//

import XCTest
@testable import BreakBuddy

private struct FakeSystem: SystemStateProviding {
    var idleSeconds: TimeInterval = 0
    var isFocusModeActive = false
}

final class ReminderSchedulerTests: XCTestCase {

    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var fired: [Reminder] = []

    private func makeScheduler(system: FakeSystem = FakeSystem()) -> (ReminderScheduler, AppSettings) {
        let suite = UserDefaults(suiteName: "BreakBuddyTests-\(UUID().uuidString)") ?? .standard
        let settings = AppSettings(defaults: suite)
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

    func testWaterFiresAfterInterval() {
        let (scheduler, _) = makeScheduler()
        advance(44 * 60, scheduler: scheduler)
        XCTAssertTrue(fired.isEmpty)
        advance(60, scheduler: scheduler)
        XCTAssertEqual(fired.map(\.type), [.water])
    }

    func testOverdueReminderShowsShortlyAfterWake() {
        let (scheduler, _) = makeScheduler()
        clock = clock.addingTimeInterval(8 * 3600) // Mac slept for 8 hours
        scheduler.tick()
        XCTAssertTrue(fired.isEmpty)               // nothing the instant it wakes
        advance(65, scheduler: scheduler)
        // Exactly one reminder per type, not a pile of missed ones.
        XCTAssertEqual(fired.filter { $0.type == .water }.count, 1)
        XCTAssertEqual(fired.filter { $0.type == .breakTime }.count, 1)
    }

    func testNotYetDueReminderKeepsRemainingTimeAfterWake() {
        let (scheduler, _) = makeScheduler()
        let due = scheduler.nextFireDate(for: .water)
        clock = clock.addingTimeInterval(30 * 60) // slept 30 of the 45 minutes
        scheduler.handleWake()
        XCTAssertEqual(scheduler.nextFireDate(for: .water), due)
    }

    func testPausedDoesNotFire() {
        let (scheduler, _) = makeScheduler()
        scheduler.pause()
        advance(2 * 3600, scheduler: scheduler)
        XCTAssertTrue(fired.isEmpty)
    }

    func testIdleUserIsSkipped() {
        var system = FakeSystem()
        system.idleSeconds = 600
        let (scheduler, _) = makeScheduler(system: system)
        advance(46 * 60, scheduler: scheduler)
        XCTAssertTrue(fired.isEmpty)
    }

    func testSnoozeMovesNextFire() {
        let (scheduler, _) = makeScheduler()
        scheduler.snooze(.water, minutes: 10)
        advance(9 * 60, scheduler: scheduler)
        XCTAssertTrue(fired.isEmpty)
        advance(90, scheduler: scheduler)
        XCTAssertEqual(fired.first?.type, .water)
    }

    func testDisabledTypeNeverFires() {
        let (scheduler, settings) = makeScheduler()
        settings.water.enabled = false
        advance(50 * 60, scheduler: scheduler)
        XCTAssertFalse(fired.contains { $0.type == .water })
    }
}
