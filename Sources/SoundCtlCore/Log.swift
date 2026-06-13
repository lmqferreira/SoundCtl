import Foundation

/// Minimal file logger for diagnosing runtime behaviour (the menu-bar agent has
/// no console). Writes to /tmp/soundctl.log.
enum Log {
    private static let url = URL(fileURLWithPath: "/tmp/soundctl.log")
    private static let queue = DispatchQueue(label: "soundctl.log")

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
