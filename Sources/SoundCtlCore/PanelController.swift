import AppKit
import SwiftUI

/// A borderless window that can become key AND main — required so the SwiftUI
/// slider renders with its active accent fill (a child/non-main window leaves it
/// grey until clicked).
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// NSHostingView that reports when its SwiftUI content's fitting size changes, so
/// the hosting windows can resize to fit (the device list grows/shrinks, and the
/// first layout pass settles slightly after the window is first shown).
final class SizingHostingView: NSHostingView<SoundPopoverView> {
    var onContentSizeChange: ((NSSize) -> Void)?
    private var reported: NSSize = .zero

    override func layout() {
        super.layout()
        let size = fittingSize
        guard size.width > 0, size.height > 0 else { return }
        if abs(size.width - reported.width) > 0.5 || abs(size.height - reported.height) > 0.5 {
            reported = size
            onContentSizeChange?(size)
        }
    }
}

/// Hosts the Sound popover using the validated two-window recipe:
///   • a glass window (real NSGlassEffectView, the exact native material), and
///   • a transparent content window layered ON TOP hosting the SwiftUI view.
/// The slider lives outside the glass view tree, so it doesn't pick up the
/// Liquid-Glass knob border; the content window is the key/main parent so the
/// fill is accent-blue, and the glass is a mouse-transparent child that follows.
final class PanelController {

    private let contentWindow: KeyableWindow
    private let glassWindow: NSWindow
    private let hosting: SizingHostingView
    private let model: PopoverModel

    private(set) var isShown = false
    private var resignObserver: NSObjectProtocol?
    private var lastCloseTime: Date?
    /// Screen-space top-left the popover is anchored to (so it grows downward).
    private var anchorTopLeft: NSPoint?

    var onVisibilityChanged: ((Bool) -> Void)?

    init(model: PopoverModel) {
        self.model = model
        hosting = SizingHostingView(rootView: SoundPopoverView(model: model))

        contentWindow = KeyableWindow(contentRect: .zero, styleMask: [.borderless],
                                      backing: .buffered, defer: true)
        contentWindow.isOpaque = false
        contentWindow.backgroundColor = .clear
        contentWindow.hasShadow = false
        contentWindow.level = .statusBar
        contentWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentWindow.contentView = hosting

        glassWindow = NSWindow(contentRect: .zero, styleMask: [.borderless],
                               backing: .buffered, defer: true)
        glassWindow.isOpaque = false
        glassWindow.backgroundColor = .clear
        glassWindow.hasShadow = true
        glassWindow.level = .statusBar
        glassWindow.isMovable = false
        glassWindow.ignoresMouseEvents = true   // all input goes to the content window
        glassWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 13
            glassWindow.contentView = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 13
            glassWindow.contentView = effect
        }

        hosting.onContentSizeChange = { [weak self] size in
            self?.resizeToContent(size)
        }
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if isShown {
            close()
        } else {
            if let t = lastCloseTime, Date().timeIntervalSince(t) < 0.25 { return }
            show(relativeTo: button)
        }
    }

    func show(relativeTo button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = layoutContent()
        let origin = Self.computeOrigin(buttonFrame: buttonFrame, contentSize: size, visibleFrame: visible)
        present(at: origin, size: size, observeResign: true)
    }

    /// Debug helper: show the popover at a fixed screen origin and keep it open.
    func debugShow(at origin: NSPoint) {
        let size = layoutContent()
        present(at: origin, size: size, observeResign: false)
    }

    private func layoutContent() -> NSSize {
        model.reload()
        // Force SwiftUI to lay out at the fixed content width *before* measuring,
        // so the first frame already fits the (reloaded) device list instead of
        // settling a beat later.
        let width = SoundPopoverView.contentWidth
        hosting.setFrameSize(NSSize(width: width, height: 2000))
        hosting.layoutSubtreeIfNeeded()
        return NSSize(width: width, height: hosting.fittingSize.height)
    }

    private func present(at origin: NSPoint, size: NSSize, observeResign: Bool) {
        anchorTopLeft = NSPoint(x: origin.x, y: origin.y + size.height)
        let frame = NSRect(origin: origin, size: size)
        glassWindow.setFrame(frame, display: true)
        contentWindow.setFrame(frame, display: true)
        if glassWindow.parent == nil {
            contentWindow.addChildWindow(glassWindow, ordered: .below)
        }

        contentWindow.makeKeyAndOrderFront(nil)
        contentWindow.makeMain()
        contentWindow.makeFirstResponder(nil)   // no keyboard focus ring on the slider
        NSApp.activate(ignoringOtherApps: true)

        isShown = true
        onVisibilityChanged?(true)
        if observeResign {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: contentWindow, queue: .main) { [weak self] _ in
                self?.close()
            }
        }
    }

    func close() {
        guard isShown else { return }
        isShown = false
        lastCloseTime = Date()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        onVisibilityChanged?(false)
        if glassWindow.parent != nil { contentWindow.removeChildWindow(glassWindow) }
        glassWindow.orderOut(nil)
        contentWindow.orderOut(nil)
        anchorTopLeft = nil
    }

    /// Keeps the popover pinned to its top-left anchor while the content's
    /// fitting size settles (so it grows downward, never spilling past the glass).
    private func resizeToContent(_ contentSize: NSSize) {
        guard isShown, let top = anchorTopLeft else { return }
        let size = NSSize(width: SoundPopoverView.contentWidth, height: contentSize.height)
        let frame = NSRect(x: top.x, y: top.y - size.height, width: size.width, height: size.height)
        guard frame != contentWindow.frame else { return }
        glassWindow.setFrame(frame, display: true)
        contentWindow.setFrame(frame, display: true)
    }

    /// Bottom-left origin: shown to the right of the icon by default
    /// (left-aligned, extends right); flips left near the right screen edge.
    static func computeOrigin(buttonFrame: NSRect,
                              contentSize: NSSize,
                              visibleFrame: NSRect,
                              gap: CGFloat = 6,
                              margin: CGFloat = 8) -> NSPoint {
        var originX = buttonFrame.minX
        if originX + contentSize.width > visibleFrame.maxX - margin {
            originX = buttonFrame.maxX - contentSize.width
        }
        originX = min(max(originX, visibleFrame.minX + margin),
                      visibleFrame.maxX - margin - contentSize.width)
        var originY = buttonFrame.minY - gap - contentSize.height
        if originY < visibleFrame.minY + margin {
            originY = visibleFrame.minY + margin
        }
        return NSPoint(x: originX, y: originY)
    }
}
