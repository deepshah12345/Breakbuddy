//
//  SystemState.swift
//  BreakBuddy
//
//  Real implementation of SystemStateProviding: idle time + Focus detection.
//

import Foundation
import CoreGraphics

struct SystemState: SystemStateProviding {

    /// Seconds since the last user input. `CGEventSource` reports idle time per
    /// event type, so we take the smallest across the common input types.
    var idleSeconds: TimeInterval {
        let inputTypes: [CGEventType] = [
            .mouseMoved, .leftMouseDown, .rightMouseDown,
            .keyDown, .scrollWheel
        ]
        let values = inputTypes.map {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }
        return values.min() ?? 0
    }

    /// Best-effort Do Not Disturb / Focus detection.
    ///
    /// Apple has no public API for this. We read the Focus assertions file that
    /// macOS maintains. Because this app is NOT sandboxed that works, but macOS
    /// only lets the app read the file if it has Full Disk Access (System
    /// Settings > Privacy & Security > Full Disk Access). Without it the read
    /// fails and we report "not active" (i.e. reminders are never wrongly blocked).
    var isFocusModeActive: Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["data"] as? [[String: Any]] else {
            return false
        }
        // A non-empty storeAssertionRecords list means some Focus is turned on.
        return entries.contains { entry in
            if let records = entry["storeAssertionRecords"] as? [Any] { return !records.isEmpty }
            return false
        }
    }
}
