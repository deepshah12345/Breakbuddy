//
//  CharacterStore.swift
//  BreakBuddy
//
//  Supplies the character images. Lookup order for each slot:
//    1. A custom PNG the user chose in Settings (stored in Application Support)
//    2. The image in the asset catalog (character_idle / _blink / _wave)
//    3. For "idle" only: a shape drawn in code, so there is always something to show
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

    /// Bumped whenever an image changes so SwiftUI views refresh.
    @Published private(set) var revision = 0

    private var cache: [Slot: NSImage] = [:]
    private let folder: URL

    init(fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        folder = base.appendingPathComponent("BreakBuddy", isDirectory: true)
    }

    // MARK: Lookup

    /// The image for a slot, or nil if the optional slot has nothing.
    func image(for slot: Slot) -> NSImage? {
        if let cached = cache[slot] { return cached }

        var result: NSImage?
        if let custom = NSImage(contentsOf: fileURL(for: slot)) {
            result = custom
        } else if let bundled = NSImage(named: NSImage.Name(slot.assetName)) {
            result = bundled
        } else if slot == .idle {
            result = CharacterStore.drawnFallback()
        }
        if let result = result { cache[slot] = result }
        return result
    }

    /// The idle image is always available thanks to the drawn fallback.
    func idleImage() -> NSImage {
        image(for: .idle) ?? CharacterStore.drawnFallback()
    }

    func hasCustomImage(for slot: Slot) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: slot).path)
    }

    // MARK: Changing images

    /// Copies the chosen image into Application Support (converted to PNG).
    func importImage(from url: URL, slot: Slot) throws {
        guard let image = NSImage(contentsOf: url),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw StoreError.unreadableImage
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: fileURL(for: slot), options: .atomic)
        } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }
        invalidate()
    }

    /// Removes the custom image so the built-in one is used again.
    func resetCustomImage(for slot: Slot) {
        try? FileManager.default.removeItem(at: fileURL(for: slot))
        invalidate()
    }

    // MARK: Private

    private func fileURL(for slot: Slot) -> URL {
        folder.appendingPathComponent("\(slot.assetName).png")
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
