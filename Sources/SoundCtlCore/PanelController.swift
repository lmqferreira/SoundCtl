import AppKit
import SwiftUI

/// A borderless window that can become key AND main — required so the SwiftUI
/// slider renders with its active accent fill (a child/non-main window leaves it
/// grey until clicked).
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
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
    private let hosting: NSHostingView<SoundPopoverView>
    private let model: PopoverModel

    private(set) var isShown = false
    private var resignObserver: NSObjectProtocol?
    private var lastCloseTime: Date?

    var onVisibilityChanged: ((Bool) -> Void)?

    init(model: PopoverModel) {
        self.model = model
        hosting = NSHostingView(rootView: SoundPopoverView(model: model))

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
        model.reload()
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)

        guard let buttonWindow = button.window else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = Self.computeOrigin(buttonFrame: buttonFrame, contentSize: size, visibleFrame: visible)
        let frame = NSRect(origin: origin, size: size)

        glassWindow.setFrame(frame, display: true)
        contentWindow.setFrame(frame, display: true)
        if glassWindow.parent == nil {
            contentWindow.addChildWindow(glassWindow, ordered: .below)
        }

        contentWindow.makeKeyAndOrderFront(nil)
        contentWindow.makeMain()
        NSApp.activate(ignoringOtherApps: true)

        isShown = true
        onVisibilityChanged?(true)
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: contentWindow, queue: .main) { [weak self] _ in
            self?.close()
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
