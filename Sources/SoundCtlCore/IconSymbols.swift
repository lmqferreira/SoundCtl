import Foundation

/// Single source of truth for which speaker SF Symbol to show, so the menu-bar
/// icon and the popover glyphs stay consistent (and unit-testable).
enum IconSymbols {

    /// Menu-bar status icon: the muted (slash) speaker at zero/mute, otherwise
    /// the variable 3-arc speaker whose arcs grey out with the level.
    static func statusBar(muted: Bool) -> String {
        muted ? "speaker.slash.fill" : "speaker.wave.3.fill"
    }

    /// Low-side glyph beside the slider: plain speaker, or slash when muted.
    static func leftFlank(muted: Bool) -> String {
        muted ? "speaker.slash.fill" : "speaker.fill"
    }

    /// High-side glyph beside the slider (always the variable 3-arc speaker).
    static let rightFlank = "speaker.wave.3.fill"
}
