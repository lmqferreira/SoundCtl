import AppKit
import SwiftUI

/// A borderless window that can become key AND main — required so the SwiftUI
/// slider renders with its active accent fill.
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// NSHostingView that reports when its SwiftUI content's fitting size changes, so
/// the window can resize to fit (the device list grows/shrinks).
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

/// Hosts the Sound popover in a single borderless key window backed by the real
/// Liquid Glass material (NSGlassEffectView). The slider knob stays clean because
/// the keyboard focus ring is disabled (that ring — not the glass — was the
/// "border"); the window is key/main so the fill renders accent-blue.
final class PanelController {

    private let window: KeyableWindow
    private let glass: NSView
    private var hosting: SizingHostingView
    private let model: PopoverModel

    private(set) var isShown = false
    private var resignObserver: NSObjectProtocol?
    private var lastCloseTime: Date?
    private var anchorTopLeft: NSPoint?

    var onVisibilityChanged: ((Bool) -> Void)?

    init(model: PopoverModel) {
        self.model = model
        hosting = SizingHostingView(rootView: SoundPopoverView(model: model))

        window = KeyableWindow(contentRect: .zero, styleMask: [.borderless],
                               backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = 13
            glass = g
        } else {
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 13
            glass = effect
        }
        window.contentView = glass
        installHosting()
    }

    /// Installs a fresh hosting view inside the glass. Rebuilt on every show
    /// because an NSHostingView whose window was ordered out can come back blank;
    /// the SwiftUI state lives in the model, so nothing is lost.
    private func installHosting() {
        hosting = SizingHostingView(rootView: SoundPopoverView(model: model))
        hosting.onContentSizeChange = { [weak self] size in
            self?.resizeToContent(size)
        }
        if #available(macOS 26.0, *), let g = glass as? NSGlassEffectView {
            g.contentView = hosting
        } else {
            hosting.translatesAutoresizingMaskIntoConstraints = false
            glass.subviews.forEach { $0.removeFromSuperview() }
            glass.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: glass.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: glass.bottomAnchor)
            ])
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
        installHosting()
        model.reload()
        let width = SoundPopoverView.contentWidth
        window.setContentSize(NSSize(width: width, height: 2000))
        glass.layoutSubtreeIfNeeded()
        return NSSize(width: width, height: hosting.fittingSize.height)
    }

    private func present(at origin: NSPoint, size: NSSize, observeResign: Bool) {
        anchorTopLeft = NSPoint(x: origin.x, y: origin.y + size.height)
        window.setFrame(NSRect(origin: origin, size: size), display: true)

        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        window.makeFirstResponder(nil)   // no keyboard focus ring on the slider
        NSApp.activate(ignoringOtherApps: true)

        isShown = true
        onVisibilityChanged?(true)
        if observeResign {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
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
        window.orderOut(nil)
        anchorTopLeft = nil
    }

    /// Keeps the popover pinned to its top-left anchor while the content's
    /// fitting size settles (so it grows downward, never spilling past the glass).
    private func resizeToContent(_ contentSize: NSSize) {
        guard isShown, let top = anchorTopLeft else { return }
        let size = NSSize(width: SoundPopoverView.contentWidth, height: contentSize.height)
        let frame = NSRect(x: top.x, y: top.y - size.height, width: size.width, height: size.height)
        guard frame != window.frame else { return }
        window.setFrame(frame, display: true)
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
