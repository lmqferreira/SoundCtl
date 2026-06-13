import AppKit

/// An image view that reports clicks via `mouseDown` (gesture recognizers don't
/// reliably fire inside an NSMenu's modal tracking loop). Used for the slider's
/// tappable speaker glyphs.
final class ClickableGlyphView: NSImageView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if bounds.contains(p) { onClick?() }
    }
}
