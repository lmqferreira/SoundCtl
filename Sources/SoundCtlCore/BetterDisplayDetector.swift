import AppKit

/// Detects whether BetterDisplay is currently running, so SoundCtl can defer the
/// hardware volume keys to it (avoiding double-handling) and only take over when
/// BetterDisplay isn't present.
struct BetterDisplayDetector {

    /// Injectable for tests; defaults to the live running-applications list.
    var runningBundleIDs: () -> [String] = {
        NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
    }

    var isRunning: Bool {
        runningBundleIDs().contains { $0.lowercased().contains("betterdisplay") }
    }
}
