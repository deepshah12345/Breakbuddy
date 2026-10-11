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
    private let onPreview: (ReminderType) -> Void

    init(settings: AppSettings, characters: CharacterStore, onPreview: @escaping (ReminderType) -> Void) {
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
    let onPreview: (ReminderType) -> Void

    var body: some View {
        Form {
            ForEach(ReminderType.allCases) { type in
                ReminderSection(type: type, settings: settings, onPreview: onPreview)
            }

            Section("Working hours") {
                Toggle("Only remind me during working hours", isOn: $settings.workingHoursEnabled)
                if settings.workingHoursEnabled {
                    DatePicker("From", selection: timeBinding(\.workStartMinutes), displayedComponents: .hourAndMinute)
                    DatePicker("To", selection: timeBinding(\.workEndMinutes), displayedComponents: .hourAndMinute)
                    Toggle("Weekdays only (Mon–Fri)", isOn: $settings.weekdaysOnly)
                }
            }

            Section("General") {
                Toggle("Play a sound with reminders", isOn: $settings.soundEnabled)
                Toggle("Skip reminders during Do Not Disturb / Focus", isOn: $settings.respectFocus)
                LaunchAtLoginToggle()
            }

            Section("Character") {
                ForEach(CharacterStore.Slot.allCases) { slot in
                    CharacterSlotRow(slot: slot, characters: characters)
                }
                Text("Use transparent PNGs. Blink and wave are optional.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
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

// MARK: - One reminder type (enable, interval, messages)

private struct ReminderSection: View {
    let type: ReminderType
    @ObservedObject var settings: AppSettings
    let onPreview: (ReminderType) -> Void

    private var config: Binding<ReminderConfig> {
        Binding(
            get: { settings.config(for: type) },
            set: { settings.setConfig($0, for: type) }
        )
    }

    var body: some View {
        Section {
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

            MessageListEditor(
                initial: config.wrappedValue.messages,
                onChange: { config.wrappedValue.messages = $0 }
            )

            Button("Preview \(type.title.lowercased()) reminder") { onPreview(type) }
        } header: {
            Label("\(type.title) reminder", systemImage: type.symbolName)
        }
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

private struct CharacterSlotRow: View {
    let slot: CharacterStore.Slot
    @ObservedObject var characters: CharacterStore
    @State private var errorMessage: String?

    var body: some View {
        HStack(spacing: 12) {
            preview
                .frame(width: 56, height: 56)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))

            VStack(alignment: .leading, spacing: 2) {
                Text(slot.title)
                Text(characters.hasCustomImage(for: slot) ? "Custom image" : "Built-in")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Choose…") { chooseImage() }
            Button("Reset") { characters.resetCustomImage(for: slot) }
                .disabled(!characters.hasCustomImage(for: slot))
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

    @ViewBuilder
    private var preview: some View {
        // Reading `revision` makes this row redraw after an image changes.
        let _ = characters.revision
        if let image = characters.image(for: slot) {
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
            try characters.importImage(from: url, slot: slot)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
