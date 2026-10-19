//
//  Models.swift
//  BreakBuddy
//
//  Core value types (ReminderDefinition, ReminderConfig, Reminder) and the persisted
//  AppSettings object. Everything is stored in UserDefaults so settings survive
//  relaunches. All of this code is expected to run on the main thread.
//

import Foundation
import Combine
import SwiftUI
import AppKit

// MARK: - Built-in reminder ids

/// The two reminders every install starts with. They can be disabled but not deleted.
enum BuiltInReminder {
    static let water = "water"
    static let breakTime = "break"
    static let ids = [water, breakTime]
}

// MARK: - ReminderPosition

/// Screen corner where the character and bubble appear.
enum ReminderPosition: String, CaseIterable, Identifiable {
    case topLeft, topCenter, topRight
    case middleLeft, middleRight
    case bottomLeft, bottomCenter, bottomRight

    enum Column { case left, center, right }
    enum Row { case top, middle, bottom }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topLeft: return "Top left"
        case .topCenter: return "Top middle"
        case .topRight: return "Top right"
        case .middleLeft: return "Left middle"
        case .middleRight: return "Right middle"
        case .bottomLeft: return "Bottom left"
        case .bottomCenter: return "Bottom middle"
        case .bottomRight: return "Bottom right"
        }
    }

    var column: Column {
        switch self {
        case .topLeft, .middleLeft, .bottomLeft: return .left
        case .topCenter, .bottomCenter: return .center
        case .topRight, .middleRight, .bottomRight: return .right
        }
    }

    var row: Row {
        switch self {
        case .topLeft, .topCenter, .topRight: return .top
        case .middleLeft, .middleRight: return .middle
        case .bottomLeft, .bottomCenter, .bottomRight: return .bottom
        }
    }
}

// MARK: - ReminderConfig

/// User-editable configuration for one reminder.
struct ReminderConfig: Codable, Equatable {
    var enabled: Bool
    var intervalMinutes: Int
    var messages: [String]
    /// When true the popup stays until the user taps Done or Snooze (no ~8 s auto-dismiss).
    var stayUntilDone: Bool = false

    /// When false (default) the reminder follows the global working hours.
    /// When true it uses the schedule below instead.
    var useOwnSchedule: Bool = false
    /// Own schedule: minutes since midnight.
    var scheduleStartMinutes: Int = 9 * 60
    var scheduleEndMinutes: Int = 18 * 60
    /// Own schedule: days it may fire, as Calendar weekday numbers (Sunday = 1 ... Saturday = 7).
    var scheduleDays: [Int] = ReminderConfig.weekdayNumbers
}

extension ReminderConfig {
    /// Monday to Friday as Calendar weekday numbers.
    static let weekdayNumbers = [2, 3, 4, 5, 6]

    /// Custom decoding so settings saved by older versions (without `stayUntilDone`)
    /// still load instead of being thrown away.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        intervalMinutes = try c.decode(Int.self, forKey: .intervalMinutes)
        messages = try c.decode([String].self, forKey: .messages)
        stayUntilDone = try c.decodeIfPresent(Bool.self, forKey: .stayUntilDone) ?? false
        useOwnSchedule = try c.decodeIfPresent(Bool.self, forKey: .useOwnSchedule) ?? false
        scheduleStartMinutes = try c.decodeIfPresent(Int.self, forKey: .scheduleStartMinutes) ?? 9 * 60
        scheduleEndMinutes = try c.decodeIfPresent(Int.self, forKey: .scheduleEndMinutes) ?? 18 * 60
        scheduleDays = try c.decodeIfPresent([Int].self, forKey: .scheduleDays) ?? ReminderConfig.weekdayNumbers
    }
}

// MARK: - ReminderDefinition

/// One reminder the user has: the two built-ins plus any custom ones.
struct ReminderDefinition: Identifiable, Codable, Equatable {
    /// "water", "break", or a UUID string for custom reminders. Also used to name
    /// this reminder's character image folder.
    var id: String
    var name: String
    /// SF Symbol name shown next to the reminder in Settings and the menu.
    var symbolName: String
    var config: ReminderConfig

    var isBuiltIn: Bool { BuiltInReminder.ids.contains(id) }

    static let defaultWater = ReminderDefinition(
        id: BuiltInReminder.water,
        name: "Water",
        symbolName: "drop.fill",
        config: ReminderConfig(
            enabled: true,
            intervalMinutes: 45,
            messages: [
                "Time to drink some water!",
                "Hydration check! Grab a glass of water.",
                "Sip, sip, hooray! Have some water.",
                "Your brain is 75% water. Top it up!"
            ]
        )
    )

    static let defaultBreak = ReminderDefinition(
        id: BuiltInReminder.breakTime,
        name: "Break",
        symbolName: "figure.walk",
        config: ReminderConfig(
            enabled: true,
            intervalMinutes: 60,
            messages: [
                "Stand up, stretch, rest your eyes for 20 seconds.",
                "Break time! Look at something far away for a bit.",
                "Roll your shoulders and take a few deep breaths.",
                "Step away from the screen for a minute."
            ]
        )
    )

    /// SF Symbols offered in the icon picker for custom reminders.
    static let symbolChoices = [
        "bell.fill", "drop.fill", "figure.walk", "eye", "pills.fill", "fork.knife",
        "cup.and.saucer.fill", "figure.mind.and.body", "heart.fill", "book.fill",
        "moon.fill", "sun.max.fill", "bolt.fill"
    ]
}

// MARK: - Reminder

/// A single reminder instance that is ready to be shown.
struct Reminder: Identifiable, Equatable {
    let id = UUID()
    /// The `ReminderDefinition.id` this popup belongs to.
    let reminderID: String
    let name: String
    let symbolName: String
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
        /// All reminders (built-in + custom) as one JSON array.
        static let reminders = "reminders.v2"
        /// Older versions stored the two built-ins separately; read once to migrate.
        static let legacyWater = "config.water"
        static let legacyBreak = "config.break"
        static let soundEnabled = "soundEnabled"
        static let workingHoursEnabled = "workingHoursEnabled"
        static let workStartMinutes = "workStartMinutes"
        static let workEndMinutes = "workEndMinutes"
        static let weekdaysOnly = "weekdaysOnly"
        static let respectFocus = "respectFocus"
        static let themeColor = "themeColor"
        static let reminderPosition = "reminderPosition"
    }

    /// Default theme: the green used by the Done button.
    static let defaultThemeColor = Color(red: 0.30, green: 0.60, blue: 0.40)

    private let defaults: UserDefaults

    /// Every reminder, built-ins first, then custom ones in creation order.
    @Published private(set) var reminders: [ReminderDefinition] {
        didSet { saveReminders() }
    }

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

    /// Accent color for buttons and toggles in Settings and the reminder popup.
    @Published var themeColor: Color {
        didSet { defaults.set(AppSettings.hex(from: themeColor), forKey: Keys.themeColor) }
    }

    /// Screen corner for the popup (defaults to bottom right).
    @Published var reminderPosition: ReminderPosition {
        didSet { defaults.set(reminderPosition.rawValue, forKey: Keys.reminderPosition) }
    }

    /// `defaults` is injectable so unit tests can use an isolated suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.reminders = AppSettings.loadReminders(from: defaults)
        self.soundEnabled = defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true
        self.workingHoursEnabled = defaults.object(forKey: Keys.workingHoursEnabled) as? Bool ?? false
        self.workStartMinutes = defaults.object(forKey: Keys.workStartMinutes) as? Int ?? 9 * 60
        self.workEndMinutes = defaults.object(forKey: Keys.workEndMinutes) as? Int ?? 18 * 60
        self.weekdaysOnly = defaults.object(forKey: Keys.weekdaysOnly) as? Bool ?? true
        self.respectFocus = defaults.object(forKey: Keys.respectFocus) as? Bool ?? true
        self.reminderPosition = defaults.string(forKey: Keys.reminderPosition)
            .flatMap(ReminderPosition.init(rawValue:)) ?? .bottomRight
        self.themeColor = defaults.string(forKey: Keys.themeColor).flatMap(AppSettings.color(fromHex:))
            ?? AppSettings.defaultThemeColor
    }

    // MARK: Theme color helpers

    /// Encodes a color as "RRGGBB" (sRGB) for UserDefaults.
    static func hex(from color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .systemGreen
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", r, g, b)
    }

    /// Parses "RRGGBB", also accepting a leading "#" and surrounding whitespace (for pasted values).
    static func color(fromHex input: String) -> Color? {
        var hex = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit), let value = Int(hex, radix: 16) else { return nil }
        return Color(red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }

    // MARK: Reminder access

    /// The reminder with this id, if it still exists.
    func reminder(id: String) -> ReminderDefinition? {
        reminders.first { $0.id == id }
    }

    /// The reminder's config, or a safe disabled placeholder if it was deleted meanwhile.
    func config(for id: String) -> ReminderConfig {
        reminder(id: id)?.config ?? ReminderConfig(enabled: false, intervalMinutes: 60, messages: [])
    }

    func setConfig(_ config: ReminderConfig, for id: String) {
        guard let index = reminders.firstIndex(where: { $0.id == id }) else { return }
        reminders[index].config = config
    }

    /// Renames a reminder. Built-ins keep their names.
    func rename(_ id: String, to name: String) {
        guard let index = reminders.firstIndex(where: { $0.id == id }),
              !reminders[index].isBuiltIn else { return }
        reminders[index].name = name
    }

    /// Changes a custom reminder's icon.
    func setSymbol(_ symbolName: String, for id: String) {
        guard let index = reminders.firstIndex(where: { $0.id == id }),
              !reminders[index].isBuiltIn else { return }
        reminders[index].symbolName = symbolName
    }

    /// Adds a new custom reminder and returns its id.
    @discardableResult
    func addReminder(name: String = "New reminder", symbolName: String = "bell.fill") -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let definition = ReminderDefinition(
            id: UUID().uuidString,
            name: trimmed.isEmpty ? "New reminder" : trimmed,
            symbolName: symbolName,
            config: ReminderConfig(
                enabled: true,
                intervalMinutes: 30,
                messages: ["Time for a quick reminder!"]
            )
        )
        reminders.append(definition)
        return definition.id
    }

    /// Deletes a custom reminder (built-ins can only be disabled).
    func deleteReminder(_ id: String) {
        guard let reminder = reminder(id: id), !reminder.isBuiltIn else { return }
        reminders.removeAll { $0.id == id }
    }

    /// Picks a random message for the reminder, falling back to sensible text if
    /// the user emptied the list.
    func randomMessage(for id: String) -> String {
        guard let reminder = reminder(id: id) else { return "Time for a quick break!" }
        let own = reminder.config.messages.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if let pick = own.randomElement() { return pick }

        let builtInDefault: ReminderDefinition?
        switch id {
        case BuiltInReminder.water: builtInDefault = .defaultWater
        case BuiltInReminder.breakTime: builtInDefault = .defaultBreak
        default: builtInDefault = nil
        }
        return builtInDefault?.config.messages.randomElement() ?? "\(reminder.name)!"
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

    /// True if the given reminder may fire at `date`: its own schedule when it has one,
    /// otherwise the global working hours.
    func isReminderActive(_ reminderID: String, at date: Date, calendar: Calendar = .current) -> Bool {
        let config = self.config(for: reminderID)
        guard config.useOwnSchedule else { return isWithinWorkingHours(date, calendar: calendar) }

        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        if let weekday = parts.weekday, !config.scheduleDays.contains(weekday) { return false }
        let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let start = config.scheduleStartMinutes, end = config.scheduleEndMinutes
        if start <= end { return minutes >= start && minutes < end }
        return minutes >= start || minutes < end // crosses midnight
    }

    // MARK: Persistence helpers

    private func saveReminders() {
        if let data = try? JSONEncoder().encode(reminders) {
            defaults.set(data, forKey: Keys.reminders)
        }
    }

    /// Loads the reminder list. On first launch after upgrading, the two built-ins
    /// are migrated from the old per-reminder keys so nobody loses their settings.
    private static func loadReminders(from defaults: UserDefaults) -> [ReminderDefinition] {
        var list: [ReminderDefinition] = []

        if let data = defaults.data(forKey: Keys.reminders),
           let decoded = try? JSONDecoder().decode([ReminderDefinition].self, from: data) {
            list = decoded
        } else {
            var water = ReminderDefinition.defaultWater
            var breakReminder = ReminderDefinition.defaultBreak
            if let legacy = legacyConfig(key: Keys.legacyWater, from: defaults) { water.config = legacy }
            if let legacy = legacyConfig(key: Keys.legacyBreak, from: defaults) { breakReminder.config = legacy }
            list = [water, breakReminder]
        }

        // Make sure both built-ins exist and come first, in a stable order.
        let custom = list.filter { !$0.isBuiltIn }
        let water = list.first { $0.id == BuiltInReminder.water } ?? .defaultWater
        let breakReminder = list.first { $0.id == BuiltInReminder.breakTime } ?? .defaultBreak
        return [water, breakReminder] + custom
    }

    private static func legacyConfig(key: String, from defaults: UserDefaults) -> ReminderConfig? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ReminderConfig.self, from: data)
    }
}
