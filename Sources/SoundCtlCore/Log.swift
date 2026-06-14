import os

/// Lightweight wrapper over unified logging (visible in Console.app under the
/// "com.lmqferreira.soundctl" subsystem). Replaces the old /tmp file logger.
enum Log {
    private static let logger = Logger(subsystem: "com.lmqferreira.soundctl", category: "soundctl")

    static func write(_ message: String) {
        logger.log("\(message, privacy: .public)")
    }
}
