//
//  Models.swift
//  BreakBuddy
//
//  Core value types (ReminderType, ReminderConfig, Reminder) and the persisted
//  AppSettings object. Everything is stored in UserDefaults so settings survive
//  relaunches. All of this code is expected to run on the main thread.
//

import Foundation
import Combine

// MARK: - ReminderType

/// The two independent kinds of reminder. Each has its own interval + messages.
enum ReminderType: String, CaseIterable, Identifiable, Codable {
    case water
    case breakTime = "break"

    var id: String { rawValue }

    /// Human-readable name used in menus and Settings.
    var title: String {
        switch self {
        case .water: return "Water"
        case .breakTime: return "Break"
        }
    }

    /// SF Symbol shown next to the type in Settings.
    var symbolName: String {
        switch self {
        case .water: return "drop.fill"
        case .breakTime: return "figure.walk"
        }
    }

    var defaultConfig: ReminderConfig {
        switch self {
        case .water:
            return ReminderConfig(
                enabled: true,
                intervalMinutes: 45,
                messages: [
                    "Time to drink some water!",
                    "Hydration check! Grab a glass of water.",
                    "Sip, sip, hooray! Have some water.",
                    "Your brain is 75% water. Top it up!"
                ]
            )
        case .breakTime:
            return ReminderConfig(
                enabled: true,
                intervalMinutes: 60,
                messages: [
                    "Stand up, stretch, rest your eyes for 20 seconds.",
                    "Break time! Look at something far away for a bit.",
                    "Roll your shoulders and take a few deep breaths.",
                    "Step away from the screen for a minute."
                ]
            )
        }
    }
}

// MARK: - ReminderConfig

/// User-editable configuration for one reminder type.
struct ReminderConfig: Codable, Equatable {
    var enabled: Bool
    var intervalMinutes: Int
    var messages: [String]
    /// When true the popup stays until the user taps Done or Snooze (no ~8 s auto-dismiss).
    var stayUntilDone: Bool = false
}

extension ReminderConfig {
    /// Custom decoding so settings saved by older versions (without `stayUntilDone`)
    /// still load instead of being thrown away.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        intervalMinutes = try c.decode(Int.self, forKey: .intervalMinutes)
        messages = try c.decode([String].self, forKey: .messages)
        stayUntilDone = try c.decodeIfPresent(Bool.self, forKey: .stayUntilDone) ?? false
    }
}

// MARK: - Reminder

/// A single reminder instance that is ready to be shown.
struct Reminder: Identifiable, Equatable {
    let id = UUID()
    let type: ReminderType
    let message: String
    let date: Date
}

// MARK: - AppSettings

/// Observable, UserDefaults-backed settings shared by the scheduler, panel and
/// Settings window. Every property saves itself in `didSet`.
final class AppSettings: ObservableObject {

    /// Snooze length used by the "Snooze 10 min" bubble button.
    static let snoozeMinutes = 10

    private enum Keys {
        static let water = "config.water"
        static let breakTime = "config.break"
        static let soundEnabled = "soundEnabled"
        static let workingHoursEnabled = "workingHoursEnabled"
        static let workStartMinutes = "workStartMinutes"
        static let workEndMinutes = "workEndMinutes"
        static let weekdaysOnly = "weekdaysOnly"
        static let respectFocus = "respectFocus"
    }

    private let defaults: UserDefaults

    // Reminder configs
    @Published var water: ReminderConfig { didSet { save(water, forKey: Keys.water) } }
    @Published var breakTime: ReminderConfig { didSet { save(breakTime, forKey: Keys.breakTime) } }

    // General
    @Published var soundEnabled: Bool {
        didSet { defaults.set(soundEnabled, forKey: Keys.soundEnabled) }
    }

    // Working hours (minutes since midnight, local time)
    @Published var workingHoursEnabled: Bool {
        didSet { defaults.set(workingHoursEnabled, forKey: Keys.workingHoursEnabled) }
    }
    @Published var workStartMinutes: Int {
        didSet { defaults.set(workStartMinutes, forKey: Keys.workStartMinutes) }
    }
    @Published var workEndMinutes: Int {
        didSet { defaults.set(workEndMinutes, forKey: Keys.workEndMinutes) }
    }
    @Published var weekdaysOnly: Bool {
        didSet { defaults.set(weekdaysOnly, forKey: Keys.weekdaysOnly) }
    }

    /// Skip reminders while Do Not Disturb / a Focus is active (best effort).
    @Published var respectFocus: Bool {
        didSet { defaults.set(respectFocus, forKey: Keys.respectFocus) }
    }

    /// `defaults` is injectable so unit tests can use an isolated suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.water = AppSettings.load(ReminderType.water.defaultConfig, key: Keys.water, from: defaults)
        self.breakTime = AppSettings.load(ReminderType.breakTime.defaultConfig, key: Keys.breakTime, from: defaults)
        self.soundEnabled = defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true
        self.workingHoursEnabled = defaults.object(forKey: Keys.workingHoursEnabled) as? Bool ?? false
        self.workStartMinutes = defaults.object(forKey: Keys.workStartMinutes) as? Int ?? 9 * 60
        self.workEndMinutes = defaults.object(forKey: Keys.workEndMinutes) as? Int ?? 18 * 60
        self.weekdaysOnly = defaults.object(forKey: Keys.weekdaysOnly) as? Bool ?? true
        self.respectFocus = defaults.object(forKey: Keys.respectFocus) as? Bool ?? true
    }

    // MARK: Config access

    func config(for type: ReminderType) -> ReminderConfig {
        switch type {
        case .water: return water
        case .breakTime: return breakTime
        }
    }

    func setConfig(_ config: ReminderConfig, for type: ReminderType) {
        switch type {
        case .water: water = config
        case .breakTime: breakTime = config
        }
    }

    /// Picks a random message for the type, falling back to the defaults if the
    /// user emptied the list.
    func randomMessage(for type: ReminderType) -> String {
        let own = config(for: type).messages.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if let pick = own.randomElement() { return pick }
        return type.defaultConfig.messages.randomElement() ?? "Time for a quick break!"
    }

    // MARK: Working hours

    /// True if `date` is inside the configured working window (always true when
    /// the feature is turned off). Supports windows that cross midnight.
    func isWithinWorkingHours(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard workingHoursEnabled else { return true }
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        if weekdaysOnly, let weekday = parts.weekday, weekday == 1 || weekday == 7 {
            return false // Sunday = 1, Saturday = 7
        }
        let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if workStartMinutes <= workEndMinutes {
            return minutes >= workStartMinutes && minutes < workEndMinutes
        }
        return minutes >= workStartMinutes || minutes < workEndMinutes
    }

    // MARK: Persistence helpers

    private func save(_ config: ReminderConfig, forKey key: String) {
        if let data = try? JSONEncoder().encode(config) {
            defaults.set(data, forKey: key)
        }
    }

    private static func load(_ fallback: ReminderConfig, key: String, from defaults: UserDefaults) -> ReminderConfig {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(ReminderConfig.self, from: data) else {
            return fallback
        }
        return decoded
    }
}
