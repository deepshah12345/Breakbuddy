//
//  SettingsView.swift
//  BreakBuddy
//
//  The Settings window (SwiftUI) plus the small AppKit controller that hosts it.
//  A menu bar app has no regular app menu, so we open our own NSWindow instead
//  of using the SwiftUI `Settings` scene.
//

import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Window controller

final class SettingsWindowController {
    private var window: NSWindow?
    private let settings: AppSettings
    private let characters: CharacterStore
    private let onPreview: (String) -> Void

    init(settings: AppSettings, characters: CharacterStore, onPreview: @escaping (String) -> Void) {
        self.settings = settings
        self.characters = characters
        self.onPreview = onPreview
    }

    /// Opens (or re-focuses) the Settings window.
    func show() {
        if window == nil {
            let root = SettingsView(settings: settings, characters: characters, onPreview: onPreview)
            let hosting = NSHostingController(rootView: root)
            let newWindow = NSWindow(contentViewController: hosting)
            newWindow.title = "BreakBuddy Settings"
            newWindow.styleMask = [.titled, .closable, .miniaturizable]
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            window = newWindow
        }
        // We're an accessory app: activate so the window comes to the front and can take typing.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Settings view

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var characters: CharacterStore
    let onPreview: (String) -> Void

    var body: some View {
        Form {
            ForEach(settings.reminders) { reminder in
                ReminderSection(reminderID: reminder.id, settings: settings,
                                characters: characters, onPreview: onPreview)
            }

            Section {
                Button {
                    settings.addReminder()
                } label: {
                    Label("Add custom reminder", systemImage: "plus.circle.fill")
                }
                Text("Create your own reminders, each with its own interval, messages and character.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Working hours") {
                Toggle("Only remind me during working hours", isOn: $settings.workingHoursEnabled)
                if settings.workingHoursEnabled {
                    DatePicker("From", selection: timeBinding(\.workStartMinutes), displayedComponents: .hourAndMinute)
                    DatePicker("To", selection: timeBinding(\.workEndMinutes), displayedComponents: .hourAndMinute)
                    Toggle("Weekdays only (Mon–Fri)", isOn: $settings.weekdaysOnly)
                }
            }

            Section("Appearance") {
                HStack {
                    Text("Theme color")
                    Spacer()
                    HexColorField(color: $settings.themeColor)
                    ColorPicker("Theme color", selection: $settings.themeColor, supportsOpacity: false)
                        .labelsHidden()
                }
                Button("Reset to default") { settings.themeColor = AppSettings.defaultThemeColor }
            }

            Section("Position") {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show character at")
                        Text(settings.reminderPosition.title)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    PositionPicker(selection: $settings.reminderPosition, accent: settings.themeColor)
                }
            }

            Section("General") {
                Toggle("Play a sound with reminders", isOn: $settings.soundEnabled)
                Toggle("Skip reminders during Do Not Disturb / Focus", isOn: $settings.respectFocus)
                LaunchAtLoginToggle()
            }

            Section("Default character") {
                ForEach(CharacterStore.Slot.allCases) { slot in
                    CharacterSlotRow(slot: slot, reminderID: nil, characters: characters)
                }
                Text("Used by every reminder that doesn't have its own character. Use transparent PNGs; blink and wave are optional.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .tint(settings.themeColor)
        .frame(width: 540, height: 680)
    }

    /// Bridges a "minutes since midnight" setting to the Date that DatePicker needs.
    private func timeBinding(_ keyPath: ReferenceWritableKeyPath<AppSettings, Int>) -> Binding<Date> {
        Binding(
            get: {
                let minutes = settings[keyPath: keyPath]
                return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60,
                                             second: 0, of: Date()) ?? Date()
            },
            set: { newDate in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                settings[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }
}

// MARK: - Position picker

/// A miniature screen with a 3x3 grid of spots; click one to place the character there.
/// The center cell is unused (the popup would cover the middle of the screen).
private struct PositionPicker: View {
    @Binding var selection: ReminderPosition
    let accent: Color

    private static let grid: [[ReminderPosition?]] = [
        [.topLeft, .topCenter, .topRight],
        [.middleLeft, nil, .middleRight],
        [.bottomLeft, .bottomCenter, .bottomRight]
    ]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { column in
                        cell(Self.grid[row][column])
                    }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
    }

    @ViewBuilder
    private func cell(_ position: ReminderPosition?) -> some View {
        if let position {
            let isSelected = position == selection
            Button { selection = position } label: {
                RoundedRectangle(cornerRadius: 5)
                    .fill(isSelected ? accent : Color.secondary.opacity(0.25))
                    .frame(width: 32, height: 22)
            }
            .buttonStyle(.plain)
            .help(position.title)
            .accessibilityLabel(position.title)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            Color.clear.frame(width: 32, height: 22)
        }
    }
}

// MARK: - Hex color field

/// Shows a color as "#RRGGBB" and lets the user type or paste a hex value.
/// Invalid input is kept as typed (and flagged) until it parses or the field loses focus.
private struct HexColorField: View {
    @Binding var color: Color
    @State private var text = ""
    @FocusState private var focused: Bool

    private var isValid: Bool { AppSettings.color(fromHex: text) != nil }

    var body: some View {
        TextField("", text: $text)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .frame(width: 90)
            .focused($focused)
            .foregroundColor(isValid || text.isEmpty ? .primary : .red)
            .onAppear { text = "#" + AppSettings.hex(from: color) }
            .onChange(of: text) { newValue in
                if let parsed = AppSettings.color(fromHex: newValue),
                   AppSettings.hex(from: parsed) != AppSettings.hex(from: color) {
                    color = parsed
                }
            }
            .onChange(of: color) { newColor in
                // Picker changed: reflect it, unless the typed text already means this color.
                let hex = AppSettings.hex(from: newColor)
                if AppSettings.color(fromHex: text).map(AppSettings.hex(from:)) != hex {
                    text = "#" + hex
                }
            }
            .onChange(of: focused) { isFocused in
                // Revert invalid text when leaving the field.
                if !isFocused { text = "#" + AppSettings.hex(from: color) }
            }
    }
}

// MARK: - Per-reminder schedule

/// From / To time pickers and a Mon-Sun day picker for one reminder's own schedule.
private struct ScheduleEditor: View {
    @Binding var config: ReminderConfig

    /// Calendar weekday numbers in display order (Monday first).
    private let days: [(number: Int, label: String)] = [
        (2, "Mon"), (3, "Tue"), (4, "Wed"), (5, "Thu"), (6, "Fri"), (7, "Sat"), (1, "Sun")
    ]

    private func timeBinding(_ keyPath: WritableKeyPath<ReminderConfig, Int>) -> Binding<Date> {
        Binding(
            get: {
                let minutes = config[keyPath: keyPath]
                return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60,
                                             second: 0, of: Date()) ?? Date()
            },
            set: { newDate in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                config[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }

    private func dayBinding(_ number: Int) -> Binding<Bool> {
        Binding(
            get: { config.scheduleDays.contains(number) },
            set: { isOn in
                var set = Set(config.scheduleDays)
                if isOn { set.insert(number) } else { set.remove(number) }
                config.scheduleDays = set.sorted()
            }
        )
    }

    var body: some View {
        DatePicker("From", selection: timeBinding(\.scheduleStartMinutes), displayedComponents: .hourAndMinute)
        DatePicker("To", selection: timeBinding(\.scheduleEndMinutes), displayedComponents: .hourAndMinute)
        HStack(spacing: 4) {
            ForEach(days, id: \.number) { day in
                Toggle(day.label, isOn: dayBinding(day.number))
                    .toggleStyle(.button)
            }
        }
        if config.scheduleDays.isEmpty {
            Text("No days selected, so this reminder will never fire.")
                .font(.caption)
                .foregroundColor(.orange)
        }
    }
}

// MARK: - One reminder (enable, interval, messages, character)

private struct ReminderSection: View {
    let reminderID: String
    @ObservedObject var settings: AppSettings
    @ObservedObject var characters: CharacterStore
    let onPreview: (String) -> Void

    @State private var confirmDelete = false

    private var config: Binding<ReminderConfig> {
        Binding(
            get: { settings.config(for: reminderID) },
            set: { settings.setConfig($0, for: reminderID) }
        )
    }

    var body: some View {
        // The reminder can disappear for a moment while it is being deleted.
        if let definition = settings.reminder(id: reminderID) {
            Section {
                if !definition.isBuiltIn {
                    customFields(for: definition)
                }

                Toggle("Enabled", isOn: config.enabled)

                HStack {
                    Text("Every")
                    Slider(
                        value: Binding(
                            get: { Double(config.wrappedValue.intervalMinutes) },
                            set: { config.wrappedValue.intervalMinutes = Int($0) }
                        ),
                        in: 5...180,
                        step: 5
                    )
                    Text("\(config.wrappedValue.intervalMinutes) min")
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                }
                .disabled(!config.wrappedValue.enabled)

                Toggle("Keep on screen until I tap Done", isOn: config.stayUntilDone)

                Toggle("Use its own schedule", isOn: config.useOwnSchedule)
                if config.wrappedValue.useOwnSchedule {
                    ScheduleEditor(config: config)
                } else if settings.workingHoursEnabled {
                    Text("Follows the working hours below.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                MessageListEditor(
                    initial: config.wrappedValue.messages,
                    onChange: { config.wrappedValue.messages = $0 }
                )

                DisclosureGroup {
                    ForEach(CharacterStore.Slot.allCases) { slot in
                        CharacterSlotRow(slot: slot, reminderID: reminderID, characters: characters)
                    }
                    Text("Poses you don't set here use the default character.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } label: {
                    HStack {
                        Text("Character for this reminder")
                        Spacer()
                        Text(characters.hasAnyCustomImage(reminderID: reminderID) ? "Custom" : "Default")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                HStack {
                    Button("Preview reminder") { onPreview(reminderID) }
                    Spacer()
                    if !definition.isBuiltIn {
                        Button("Delete reminder", role: .destructive) { confirmDelete = true }
                    }
                }
                .confirmationDialog(
                    "Delete \"\(definition.name)\"?",
                    isPresented: $confirmDelete,
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) {
                        characters.removeAllImages(forReminder: reminderID)
                        settings.deleteReminder(reminderID)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This also removes this reminder's character images.")
                }
            } header: {
                Label(definition.name.isEmpty ? "Untitled reminder" : "\(definition.name) reminder",
                      systemImage: definition.symbolName)
            }
        }
    }

    /// Name and icon, only editable for custom reminders.
    @ViewBuilder
    private func customFields(for definition: ReminderDefinition) -> some View {
        TextField("Name", text: Binding(
            get: { definition.name },
            set: { settings.rename(reminderID, to: $0) }
        ))

        Picker("Icon", selection: Binding(
            get: { definition.symbolName },
            set: { settings.setSymbol($0, for: reminderID) }
        )) {
            ForEach(ReminderDefinition.symbolChoices, id: \.self) { name in
                Label(name, systemImage: name)
                    .labelStyle(.iconOnly)
                    .tag(name)
            }
        }
        .pickerStyle(.menu)
    }
}

/// Edits a message list as plain text, one message per line. Keeps its own text
/// state so typing (including blank lines) is never rewritten under the cursor.
private struct MessageListEditor: View {
    let onChange: ([String]) -> Void
    @State private var text: String

    init(initial: [String], onChange: @escaping ([String]) -> Void) {
        self.onChange = onChange
        _text = State(initialValue: initial.joined(separator: "\n"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Messages (one per line, a random one is shown each time)")
                .font(.caption)
                .foregroundColor(.secondary)
            TextEditor(text: Binding(
                get: { text },
                set: { newValue in
                    text = newValue
                    let lines = newValue
                        .split(separator: "\n", omittingEmptySubsequences: true)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    onChange(lines)
                }
            ))
            .font(.system(size: 13))
            .frame(height: 84)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
        }
    }
}

// MARK: - Launch at login (SMAppService)

private struct LaunchAtLoginToggle: View {
    @State private var isOn = SMAppService.mainApp.status == .enabled
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Launch at login", isOn: Binding(
                get: { isOn },
                set: { newValue in
                    do {
                        if newValue {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                    // Always reflect the real system state, not what was requested.
                    isOn = SMAppService.mainApp.status == .enabled
                }
            ))
            if SMAppService.mainApp.status == .requiresApproval {
                Text("Approve BreakBuddy in System Settings > General > Login Items.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .alert("Couldn't change the login item", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text((errorMessage ?? "") + "\n\nTip: move BreakBuddy.app into /Applications and try again.")
        }
    }
}

// MARK: - Character image picker row

/// One pose (idle / blink / wave) for either a specific reminder (`reminderID` set)
/// or the shared default character (`reminderID` nil).
private struct CharacterSlotRow: View {
    let slot: CharacterStore.Slot
    let reminderID: String?
    @ObservedObject var characters: CharacterStore
    @State private var errorMessage: String?

    private var isCustom: Bool { characters.hasCustomImage(for: slot, reminderID: reminderID) }

    var body: some View {
        HStack(spacing: 12) {
            preview
                .frame(width: 56, height: 56)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))

            VStack(alignment: .leading, spacing: 2) {
                Text(reminderID == nil ? slot.title : slot.shortTitle)
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Choose…") { chooseImage() }
            Button("Reset") { characters.resetCustomImage(for: slot, reminderID: reminderID) }
                .disabled(!isCustom)
        }
        .alert("Couldn't use that image", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var statusText: String {
        if isCustom { return "Custom image" }
        return reminderID == nil ? "Built-in" : "Using default character"
    }

    @ViewBuilder
    private var preview: some View {
        // Reading `revision` makes this row redraw after an image changes.
        let _ = characters.revision
        if let image = characters.image(for: slot, reminderID: reminderID) {
            Image(nsImage: image).resizable().scaledToFit().padding(4)
        } else {
            Text("None").font(.caption).foregroundColor(.secondary)
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.title = "Choose a transparent PNG for “\(slot.rawValue)”"
        panel.allowedContentTypes = [.png, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try characters.importImage(from: url, slot: slot, reminderID: reminderID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
