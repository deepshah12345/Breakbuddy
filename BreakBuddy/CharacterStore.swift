//
//  CharacterStore.swift
//  BreakBuddy
//
//  Supplies the character images. Every reminder can have its own character.
//  Lookup order for each pose ("slot") of a reminder:
//    1. A custom PNG chosen for THAT reminder
//    2. The shared default character's custom PNG (chosen under "Default character")
//    3. The image in the asset catalog (character_idle / _blink / _wave)
//    4. For "idle" only: a shape drawn in code, so there is always something to show
//
//  Files live in Application Support/BreakBuddy:
//    character_<slot>.png                      shared default character
//    reminders/<reminder id>/character_<slot>.png   one reminder's own character
//

import AppKit
import Combine

final class CharacterStore: ObservableObject {

    enum Slot: String, CaseIterable, Identifiable {
        case idle, blink, wave

        var id: String { rawValue }
        /// Name of the image set in Assets.xcassets.
        var assetName: String { "character_\(rawValue)" }
        var title: String {
            switch self {
            case .idle: return "Idle (required)"
            case .blink: return "Blink (optional)"
            case .wave: return "Wave (optional)"
            }
        }
        /// Short label used for per-reminder characters (they always have a fallback).
        var shortTitle: String {
            switch self {
            case .idle: return "Idle"
            case .blink: return "Blink (optional)"
            case .wave: return "Wave (optional)"
            }
        }
    }

    enum StoreError: LocalizedError {
        case unreadableImage
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .unreadableImage: return "That file couldn't be read as an image."
            case .writeFailed(let reason): return "Couldn't save the image: \(reason)"
            }
        }
    }

    /// Cache key: which reminder (nil = shared default) and which pose.
    private struct Key: Hashable {
        let reminderID: String?
        let slot: Slot
    }

    /// Bumped whenever an image changes so SwiftUI views refresh.
    @Published private(set) var revision = 0

    private var cache: [Key: NSImage] = [:]
    private let folder: URL

    init(fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        folder = base.appendingPathComponent("BreakBuddy", isDirectory: true)
    }

    // MARK: Lookup

    /// The image to show for a pose. Pass a `reminderID` for a specific reminder, or
    /// nil for the shared default character. Returns nil only for an optional pose
    /// (blink / wave) that nothing provides.
    func image(for slot: Slot, reminderID: String? = nil) -> NSImage? {
        let key = Key(reminderID: reminderID, slot: slot)
        if let cached = cache[key] { return cached }

        var result: NSImage?
        if let id = reminderID, let own = NSImage(contentsOf: fileURL(for: slot, reminderID: id)) {
            result = own
        } else if let shared = NSImage(contentsOf: fileURL(for: slot, reminderID: nil)) {
            result = shared
        } else if let bundled = NSImage(named: NSImage.Name(slot.assetName)) {
            result = bundled
        } else if slot == .idle {
            result = CharacterStore.drawnFallback()
        }
        if let result = result { cache[key] = result }
        return result
    }

    /// The idle image is always available thanks to the drawn fallback.
    func idleImage(reminderID: String? = nil) -> NSImage {
        image(for: .idle, reminderID: reminderID) ?? CharacterStore.drawnFallback()
    }

    /// True if this exact reminder (or the shared default when nil) has its own custom file
    /// for the pose, ignoring fallbacks.
    func hasCustomImage(for slot: Slot, reminderID: String? = nil) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: slot, reminderID: reminderID).path)
    }

    /// True if the reminder has at least one custom image of its own.
    func hasAnyCustomImage(reminderID: String) -> Bool {
        Slot.allCases.contains { hasCustomImage(for: $0, reminderID: reminderID) }
    }

    // MARK: Changing images

    /// Copies the chosen image into Application Support (converted to PNG).
    func importImage(from url: URL, slot: Slot, reminderID: String? = nil) throws {
        guard let image = NSImage(contentsOf: url),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw StoreError.unreadableImage
        }
        let destination = fileURL(for: slot, reminderID: reminderID)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try png.write(to: destination, options: .atomic)
        } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }
        invalidate()
    }

    /// Removes the custom image so the next fallback is used again.
    func resetCustomImage(for slot: Slot, reminderID: String? = nil) {
        try? FileManager.default.removeItem(at: fileURL(for: slot, reminderID: reminderID))
        invalidate()
    }

    /// Deletes every image belonging to a reminder (called when a reminder is deleted).
    func removeAllImages(forReminder reminderID: String) {
        try? FileManager.default.removeItem(at: reminderFolder(for: reminderID))
        invalidate()
    }

    // MARK: Private

    /// Keeps ids safe for use as folder names.
    private func safeName(_ id: String) -> String {
        let cleaned = id.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return cleaned.isEmpty ? "reminder" : cleaned
    }

    private func reminderFolder(for reminderID: String) -> URL {
        folder.appendingPathComponent("reminders", isDirectory: true)
            .appendingPathComponent(safeName(reminderID), isDirectory: true)
    }

    private func fileURL(for slot: Slot, reminderID: String?) -> URL {
        let name = "\(slot.assetName).png"
        if let id = reminderID {
            return reminderFolder(for: id).appendingPathComponent(name)
        }
        return folder.appendingPathComponent(name)
    }

    private func invalidate() {
        cache.removeAll()
        revision += 1
    }

    /// Last-resort cartoon blob, drawn with Core Graphics, used only if the
    /// asset catalog is missing character_idle.
    private static func drawnFallback() -> NSImage {
        let size = NSSize(width: 256, height: 256)
        return NSImage(size: size, flipped: false) { rect in
            NSColor(calibratedRed: 0.36, green: 0.67, blue: 0.96, alpha: 1).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 24, dy: 24)).fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: 80, y: 130, width: 36, height: 44)).fill()
            NSBezierPath(ovalIn: NSRect(x: 140, y: 130, width: 36, height: 44)).fill()
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 94, y: 140, width: 14, height: 18)).fill()
            NSBezierPath(ovalIn: NSRect(x: 150, y: 140, width: 14, height: 18)).fill()
            let smile = NSBezierPath()
            smile.lineWidth = 6
            smile.lineCapStyle = .round
            smile.appendArc(withCenter: NSPoint(x: 128, y: 100), radius: 34, startAngle: 200, endAngle: 340)
            NSColor.black.setStroke()
            smile.stroke()
            return true
        }
    }
}
