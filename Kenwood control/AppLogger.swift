import Foundation
import os

/// Unified logger that works under the App Sandbox.
/// Use `scripts/checklogs.sh` to query via `log show`.
enum AppLogger {
    static let subsystem: String = Bundle.main.bundleIdentifier ?? "KenwoodControl"
    private static let logger = Logger(subsystem: subsystem, category: "app")

    static func info(_ message: String) {
        // Use NOTICE so it persists and is visible via `log show` without extra system configuration.
        // Mark public so logs are readable without redaction (we already redact passwords elsewhere).
        logger.notice("\(message, privacy: .public)")
        NSLog("%@", message)
        // Also emit to stderr so a Terminal-launched debug run can be captured easily.
        fputs("[INFO] \(message)\n", stderr)
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        NSLog("ERROR: %@", message)
        fputs("[ERROR] \(message)\n", stderr)
    }
}
